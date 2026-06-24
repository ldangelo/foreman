defmodule ForemanServer.SmokeTest do
  @moduledoc """
  End-to-end projection smoke suite.

  Exercises the complete Foreman event/projection lifecycle deterministically:
  - Creates a synthetic task
  - Starts a pipeline run and advances through phases
  - Simulates PR/merge events
  - Rebuilds projections and asserts run/task/event agreement

  CI-safe: each test uses an isolated temp event log, no live credentials.
  Tagged `:smoke` and `:projection`; run with `mix test --trace --only smoke:projection`.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.{EventStore, Operations, ProjectionStore}

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "foreman-smoke-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    event_log_path = Path.join(tmp_dir, "events.term.log")

    Application.stop(:foreman_server)
    Application.delete_env(:foreman_server, :event_log_path)
    Application.put_env(:foreman_server, :event_log_path, event_log_path)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      File.rm_rf!(tmp_dir)
      # Restart app so subsequent tests (non-smoke) can run
      Application.start(:foreman_server)
    end)

    assert :ok = Application.start(:foreman_server)
    %{tmp_dir: tmp_dir}
  end

  @doc """
  End-to-end projection smoke: creates a temp task, runs the pipeline,
  simulates PR/merge completion, and asserts run/task/event projections agree.
  """
  describe "end-to-end projection smoke" do
    @describetag smoke: :projection
    @describetag :projection

    test "run/task/event projections agree after pipeline + PR/merge", %{
      tmp_dir: _tmp_dir
    } do
      task_id = "smoke-task-#{System.unique_integer([:positive])}"
      run_id = "smoke-run-#{System.unique_integer([:positive])}"
      pr_id = "smoke-pr-#{System.unique_integer([:positive])}"

      # ── 1. Create a synthetic task ────────────────────────────────────────
      assert {:ok, %{event: task_event, projection: snap}} =
               ForemanServer.handle_command(%{
                 command_id: "cmd-create-#{task_id}",
                 command_type: "task.create",
                 payload: %{
                   task_id: task_id,
                   project_id: "smoke-project",
                   title: "Smoke test task",
                   status: "open"
                 }
               })

      assert task_event.event_type == "TaskCreated"
      assert snap.tasks[task_id].status == "open"

      # ── 2. Approve the task (dispatchable) ────────────────────────────────
      assert {:ok, %{event: approve_event, projection: snap}} =
               ForemanServer.handle_command(%{
                 command_id: "cmd-approve-#{task_id}",
                 command_type: "task.approve",
                 payload: %{task_id: task_id}
               })

      assert approve_event.event_type == "TaskUpdated"
      assert snap.tasks[task_id].status == "ready"

      # ── 3. Claim task and start the run ──────────────────────────────────
      append!("task:#{task_id}", "TaskUpdated", %{
        task_id: task_id,
        status: "in_progress",
        run_id: run_id
      })

      append!("run:#{run_id}", "RunStarted", %{
        run_id: run_id,
        task_id: task_id,
        phase_order: ["developer", "qa"]
      })

      # ── 4. Advance through developer phase ────────────────────────────────
      append!("run:#{run_id}", "PhaseStarted", %{
        run_id: run_id,
        phase_id: "developer",
        actor: "foreman"
      })

      append!("run:#{run_id}", "PhaseCompleted", %{
        run_id: run_id,
        phase_id: "developer"
      })

      # ── 5. Advance through QA phase ──────────────────────────────────────
      append!("run:#{run_id}", "PhaseStarted", %{
        run_id: run_id,
        phase_id: "qa",
        actor: "foreman"
      })

      append!("run:#{run_id}", "QaVerdict", %{
        run_id: run_id,
        verdict: "pass",
        phase: "qa"
      })

      append!("run:#{run_id}", "PhaseCompleted", %{
        run_id: run_id,
        phase_id: "qa"
      })

      # ── 6. Complete the run ───────────────────────────────────────────────
      append!("run:#{run_id}", "RunCompleted", %{
        run_id: run_id,
        task_id: task_id
      })

      # ── 7. Simulate PR creation ─────────────────────────────────────────
      append!("pr:#{pr_id}", "PrCreated", %{
        pr_id: pr_id,
        run_id: run_id,
        source_link: "https://smoke.test/pr/#{pr_id}"
      })

      # ── 8. Simulate PR merge ─────────────────────────────────────────────
      append!("pr:#{pr_id}", "PrMerged", %{
        pr_id: pr_id,
        run_id: run_id,
        task_id: task_id,
        source_link: "https://smoke.test/pr/#{pr_id}"
      })

      # ── 9. Rebuild projections deterministically ─────────────────────────
      assert {:ok, rebuilt} = EventStore.rebuild_projections()

      # ── 10. Assertions ───────────────────────────────────────────────────

      # Run projection: status is "merged"
      run_proj = rebuilt.runs[run_id]
      assert run_proj != nil, "run projection should exist"
      assert run_proj.status == "merged", "run should be merged"

      # Task projection: status propagated to "merged"
      task_proj = rebuilt.tasks[task_id]
      assert task_proj != nil, "task projection should exist"
      assert task_proj.status == "merged", "task should reflect merged run"
      assert task_proj.run_id == run_id

      # All events present in event store
      all_events = EventStore.all()
      event_types = Enum.map(all_events, & &1.event_type)

      assert "TaskCreated" in event_types
      assert "TaskUpdated" in event_types
      assert "RunStarted" in event_types
      assert "PhaseStarted" in event_types
      assert "PhaseCompleted" in event_types
      assert "RunCompleted" in event_types
      assert "PrCreated" in event_types
      assert "PrMerged" in event_types

      # Projection lag == 0 (rebuild catches up)
      metrics = elem(Operations.metrics(), 1)
      assert metrics.projection_lag == 0, "projection lag must be zero after rebuild"
      assert metrics.gauges.projection_lag == 0

      # Rebuild from scratch produces identical merged state
      assert {:ok, rebuilt_again} = EventStore.rebuild_projections()
      assert rebuilt_again.runs[run_id].status == "merged"
      assert rebuilt_again.tasks[task_id].status == "merged"

      # Snapshot reflects live state
      snap = ProjectionStore.snapshot()
      assert snap.runs[run_id].status == "merged"
      assert snap.tasks[task_id].status == "merged"

      # Status counts: active=0, completed/merged accounting
      assert snap.status_counts.active == 0
    end
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  defp append!(stream_id, event_type, payload) do
    {:ok, _event} =
      EventStore.append(%{
        stream_id: stream_id,
        event_type: event_type,
        payload: payload,
        metadata: %{}
      })

    :ok
  end
end
