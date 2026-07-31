defmodule ForemanServer.PrGateTest do
  use ExUnit.Case

  alias ForemanServer.{EventStore, PrGate, ProjectionStore}

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "foreman-pr-gate-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))
    assert :ok = Application.start(:foreman_server)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    :ok
  end

  test "delayed checks progress through pending and seen_pending before stable_ready" do
    assert {:ok, %{result: %{state: "pending"}}} =
             PrGate.observe(%{
               pr_id: "1",
               run_id: "run-pr-1",
               checks: "pending",
               review: "pending"
             })

    assert {:ok, %{result: %{state: "seen_pending"}}} =
             PrGate.observe(%{
               pr_id: "1",
               run_id: "run-pr-1",
               checks: "pending",
               review: "pending"
             })

    assert ProjectionStore.snapshot().pr_gates["1"].state == "seen_pending"

    assert {:ok, %{result: %{state: "stable_ready"}}} =
             PrGate.observe(%{
               pr_id: "1",
               run_id: "run-pr-1",
               checks: "success",
               review: "approved",
               stable_for_seconds: 31
             })
  end

  test "stable ready PR revalidates immediately before merge" do
    fixture = fixture()
    assert {:ok, %{result: %{state: "stable_ready"}}} = PrGate.observe(fixture["pr_gate_state"])

    assert {:ok, %{event: event}} =
             PrGate.merge(%{
               pr_id: "42",
               run_id: "run-pr-42",
               backend: fixture["backend"],
               branch: "feature/pr-42",
               target: "main"
             })

    assert event.event_type == "PrMerged"
    assert ProjectionStore.snapshot().pr_gates["42"].state == "merged"
  end

  test "merge blocked or failed reason is visible from projected events" do
    assert {:ok, %{result: %{state: "pending"}}} =
             PrGate.observe(%{
               pr_id: "2",
               run_id: "run-pr-2",
               checks: "success",
               review: "approved",
               stable_for_seconds: 5
             })

    assert {:error, {:merge_gate_not_ready, %{observed_state: "pending"}}} =
             PrGate.merge(%{
               pr_id: "2",
               run_id: "run-pr-2",
               branch: "feature/pr-2",
               target: "main"
             })

    failure = ProjectionStore.snapshot().merge_failures["2"]
    assert failure.event_type == "MergeBlocked"
    assert failure.reason == "merge_gate_not_ready"
  end

  test "check/1 accepts only open or merged PR states" do
    seed_run_with_pr_state!("run-pr-open", "PrReady", %{
      project_id: "project-open",
      task_id: "task-open",
      pr_url: "https://github.com/acme/foreman/pull/201",
      branch_name: "foreman/task-open",
      head_sha: "head-open",
      base_branch: "main"
    })

    assert :ok = PrGate.check("run-pr-open")

    seed_run_with_pr_state!("run-pr-merged", "PrMerged", %{
      project_id: "project-merged",
      task_id: "task-merged",
      pr_url: "https://github.com/acme/foreman/pull/202",
      branch_name: "foreman/task-merged"
    })

    assert :ok = PrGate.check("run-pr-merged")

    seed_run_with_pr_state!("run-pr-draft", "PrUpdated", %{
      project_id: "project-draft",
      task_id: "task-draft",
      pr_url: "https://github.com/acme/foreman/pull/203",
      branch_name: "foreman/task-draft",
      head_sha: "head-draft",
      base_branch: "main",
      phase: "developer",
      pr_state: "draft"
    })

    assert {:error, :pr_not_acceptable} = PrGate.check("run-pr-draft")

    seed_run_with_pr_state!("run-pr-closed", "PrReset", %{
      project_id: "project-closed",
      task_id: "task-closed",
      pr_url: "https://github.com/acme/foreman/pull/204",
      branch_name: "foreman/task-closed",
      action: "closed",
      reason: "closed by author"
    })

    assert {:error, :pr_not_acceptable} = PrGate.check("run-pr-closed")

    seed_run_with_pr_state!("run-pr-conflicted", "PrUpdated", %{
      project_id: "project-conflicted",
      task_id: "task-conflicted",
      pr_url: "https://github.com/acme/foreman/pull/205",
      branch_name: "foreman/task-conflicted",
      head_sha: "head-conflicted",
      base_branch: "main",
      phase: "developer",
      pr_state: "conflicted"
    })

    assert {:error, :pr_not_acceptable} = PrGate.check("run-pr-conflicted")
    assert {:error, :pr_not_acceptable} = PrGate.check("run-pr-missing")
  end

  defp seed_run_with_pr_state!(run_id, event_type, payload) do
    append!("run:#{run_id}", "RunStarted", %{
      run_id: run_id,
      task_id: Map.fetch!(payload, :task_id),
      project_id: Map.fetch!(payload, :project_id),
      status: "in_progress",
      base_branch: "main"
    })

    append!("run:#{run_id}", event_type, Map.put(payload, :run_id, run_id))

    assert ProjectionStore.snapshot().runs[run_id].run_id == run_id
  end

  defp append!(stream_id, event_type, payload) do
    {:ok, _event} =
      EventStore.append(%{
        stream_id: stream_id,
        event_type: event_type,
        payload: payload,
        metadata: %{}
      })
  end

  defp fixture do
    "test/fixtures/vcs-pr-ready-state.json"
    |> File.read!()
    |> Jason.decode!()
  end
end
