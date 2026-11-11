defmodule ForemanServer.Workflow.RunResumeBoundariesTest do
  @moduledoc """
  REQ-002 / AC-002-1: a service restart at any stage boundary of a run resumes it without
  launching a phase that already has `PhaseCompleted` again.

  A restart here is the production one: the Dispatcher is stopped, the whole read model is
  rebuilt from the committed event log (`ProjectionStore.rebuild/1`, what `init/1` does at
  boot), and the Dispatcher is started again, which replays that log into its mailbox. Runs
  and phases are made through the real command gateway, aggregates and event store.

  `RunSupervisor.start_run/3` is replaced by a recorder. That bypasses the `RunExecutor` that
  would honour `resume_from` and launch phases (its own tests cover that, TRD-007), so what
  these tests pin is the Dispatcher's decision: whether it starts the run again and from which
  phase index. `RunAdmission`, the run aggregate, the slot stream and the projection are real.

  The boundaries: (1) before a phase starts, (2) after `PhaseStarted` before completion,
  (3) after `PhaseCompleted` before the next phase, (4) waiting on a human, (5) after the last
  phase before the terminal event.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.{CommandGateway, Identity, ProjectionStore}
  import ExUnit.CaptureLog

  alias ForemanServer.TestSupport.CoordinatorHelpers, as: H
  alias ForemanServer.TestSupport.{DispatcherRestart, RunDrain, RunSlotsReset, UniqueIds}
  alias ForemanServer.TestSupport.MeckScope
  alias ForemanServer.Workflow.{Dispatcher, RunSupervisor}

  @dispatcher Dispatcher
  @app_supervisor ForemanServer.Application
  @barrier_timeout_ms 30_000

  setup_all do
    MeckScope.new_once!([RunSupervisor])
  end

  setup context do
    previous = Application.fetch_env(:foreman_server, :max_concurrent_runs)
    # The tests start several runs and the restarts re-admit all of them: a free slot is the
    # test's own to guarantee, not the default capacity's (`@tag capacity: n` narrows it).
    Application.put_env(:foreman_server, :max_concurrent_runs, Map.get(context, :capacity, 50))

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:foreman_server, :max_concurrent_runs, value)
        :error -> Application.delete_env(:foreman_server, :max_concurrent_runs)
      end
    end)

    # The app Dispatcher must be the real, subscribed one; the rebuilds below resurrect every
    # run in the log, so the store is reset again when the test is over.
    DispatcherRestart.restart!()
    on_exit(&DispatcherRestart.restart!/0)
    RunSlotsReset.reset!()

    # Both arities are recorded: a run promoted from the slot queue is started with
    # `start_run/2`, a dispatched or resumed one with `start_run/3`.
    MeckScope.restore_on_exit!([RunSupervisor])
    test = self()

    :meck.expect(RunSupervisor, :start_run, fn run_id, _task, opts ->
      send(test, {:run_supervisor_start, run_id, opts})
      {:ok, :child}
    end)

    :meck.expect(RunSupervisor, :start_run, fn run_id, _task ->
      send(test, {:run_supervisor_start, run_id, []})
      {:ok, :child}
    end)

    H.subscribe!()
    project = H.register_project(System.tmp_dir!(), config: %{})

    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        type: "project.update",
        aggregate_id: "project:#{project}",
        command_id: "u-#{System.unique_integer([:positive])}",
        payload: %{project_id: project, max_concurrent_runs: 50}
      })

    {:ok, project: project}
  end

  describe "boundary 1: before a phase starts" do
    test "the run resumes at phase 0 and its record is rebuilt", %{project: project} do
      %{run_id: run_id} = submit!(project)
      before = snapshot(run_id)
      assert before.phases == []

      restart_service!()

      assert starts(run_id) == [[resume_from: 0]]
      assert snapshot(run_id) == before
    end
  end

  describe "boundary 2: after PhaseStarted, before PhaseCompleted" do
    test "the in-flight phase restarts at its own index and its rebuilt record keeps attempt 2",
         %{project: project} do
      %{run_id: run_id} = submit!(project)
      complete_phase!(run_id, 1)
      start_phase!(run_id, 2)
      retry_phase!(run_id, 2)

      before = snapshot(run_id)

      assert [%{index: 1, status: "completed"}, %{index: 2, status: "in_progress", attempt: 2}] =
               before.phases

      restart_service!()

      assert starts(run_id) == [[resume_from: 1]]
      assert snapshot(run_id) == before
    end
  end

  describe "boundary 3: after PhaseCompleted, before the next phase" do
    test "the run resumes at the next phase, not at the completed one", %{project: project} do
      %{run_id: run_id} = submit!(project)
      complete_phase!(run_id, 1)

      before = snapshot(run_id)

      assert [%{index: 1, status: "completed", artifact: %{path: "artifacts/p1.md"}}] =
               before.phases

      restart_service!()

      assert starts(run_id) == [[resume_from: 1]]
      assert snapshot(run_id) == before
    end

    test "with several phases completed, the first unfinished one is where it resumes", %{
      project: project
    } do
      %{run_id: run_id, total: total} = submit!(project)
      assert total >= 3, "the fix workflow must have at least three phases for this test"
      complete_phase!(run_id, 1)
      complete_phase!(run_id, 2)

      before = snapshot(run_id)
      restart_service!()

      assert starts(run_id) == [[resume_from: 2]]
      assert snapshot(run_id) == before
    end
  end

  describe "boundary 4: waiting on a human" do
    test "a paused run is not restarted, and answering resumes only that run", %{
      project: project
    } do
      %{run_id: waiting_id} = submit!(project)
      %{run_id: other_waiting_id} = submit!(project)
      complete_phase!(waiting_id, 1)
      start_phase!(waiting_id, 2)
      pause!(waiting_id)
      pause!(other_waiting_id)

      before = snapshot(waiting_id)
      other_before = snapshot(other_waiting_id)
      assert before.run.status == "paused"

      restart_service!()

      # Neither paused run is started by the replay of its own dispatch.
      assert starts(waiting_id) == []
      assert starts(other_waiting_id) == []
      assert snapshot(waiting_id) == before
      assert snapshot(other_waiting_id) == other_before

      resume!(waiting_id)

      assert_receive {:run_supervisor_start, ^waiting_id, [resume_from: 1]}, 10_000
      refute_receive {:run_supervisor_start, ^other_waiting_id, _}, 500
      assert snapshot(other_waiting_id) == other_before
    end

    test "a resume already in the log does not restart a run that was paused again", %{
      project: project
    } do
      %{run_id: run_id} = submit!(project)
      complete_phase!(run_id, 1)
      pause!(run_id)
      resume!(run_id)
      assert_receive {:run_supervisor_start, ^run_id, _opts}, 10_000
      pause!(run_id)

      before = snapshot(run_id)
      assert before.run.status == "paused"

      restart_service!()

      assert starts(run_id) == []
      assert snapshot(run_id) == before
    end

    test "a resume already in the log does not restart a run that was cancelled since", %{
      project: project
    } do
      %{run_id: run_id} = submit!(project)
      complete_phase!(run_id, 1)
      pause!(run_id)
      resume!(run_id)
      assert_receive {:run_supervisor_start, ^run_id, _opts}, 10_000
      cancel!(run_id)

      before = snapshot(run_id)
      assert before.run.status == "cancelled"

      restart_service!()

      assert starts(run_id) == []
      assert snapshot(run_id) == before
    end
  end

  describe "boundary 5: after the last phase, before the terminal event" do
    test "the run resumes past the end, so no phase is launched again", %{project: project} do
      %{run_id: run_id, total: total} = submit!(project)
      for index <- 1..total, do: complete_phase!(run_id, index)

      before = snapshot(run_id)
      assert length(before.phases) == total
      assert Enum.all?(before.phases, &(&1.status == "completed"))
      assert before.run.terminal? == false

      restart_service!()

      assert starts(run_id) == [[resume_from: total]]
      assert snapshot(run_id) == before
    end
  end

  describe "a resumed run that waits for a run slot" do
    # One slot: the second run holds it while the first, resumed after its pause, waits.
    @tag capacity: 1
    test "is started from its first unfinished phase when the slot frees", %{project: project} do
      %{run_id: waiting_id} = submit!(project)
      complete_phase!(waiting_id, 1)
      pause!(waiting_id)
      %{run_id: holder_id} = submit!(project)

      resume!(waiting_id)
      _ = :sys.get_state(@dispatcher, @barrier_timeout_ms)
      refute_receive {:run_supervisor_start, ^waiting_id, _}, 300

      cancel!(holder_id)

      assert_receive {:run_supervisor_start, ^waiting_id, opts}, 10_000
      assert opts == [resume_from: 1]
    end
  end

  describe "the resume path does not fail quietly" do
    test "a RunResumed for a run the projection does not know starts nothing and warns" do
      run_id = UniqueIds.unique_run_id("unknown")
      envelope = %{event_type: "RunResumed", data: %{run_id: run_id}}

      log =
        capture_log([level: :warning], fn ->
          assert {:noreply, %{}} =
                   Dispatcher.handle_info({:projection_event, envelope}, %{})
        end)

      assert log =~ "#{run_id}, which the projection does not know"
      refute_received {:run_supervisor_start, ^run_id, _}
    end

    test "an executor that cannot be started for a resumed run is logged", %{project: project} do
      %{run_id: run_id} = submit!(project)
      complete_phase!(run_id, 1)
      pause!(run_id)

      test = self()

      :meck.expect(RunSupervisor, :start_run, fn run_id, _task, opts ->
        send(test, {:run_supervisor_start, run_id, opts})
        {:error, :max_children}
      end)

      log =
        capture_log([level: :warning], fn ->
          resume!(run_id)
          assert_receive {:run_supervisor_start, ^run_id, [resume_from: 1]}, 10_000
          _ = :sys.get_state(@dispatcher, @barrier_timeout_ms)
        end)

      assert log =~ "could not start the executor of resumed run #{run_id}"
      assert log =~ ":max_children"
    end
  end

  # -- service restart ----------------------------------------------------------------------

  # Stop the executors and the Dispatcher, rebuild the read model from the event log as boot
  # does, start the Dispatcher again (it receives the whole log) and wait until it has handled
  # all of it. Recorded starts from before the restart are discarded.
  defp restart_service!() do
    RunDrain.drain!()
    :ok = Supervisor.terminate_child(@app_supervisor, @dispatcher)
    flush_starts()
    :ok = ProjectionStore.rebuild([])
    {:ok, dispatcher} = Supervisor.restart_child(@app_supervisor, @dispatcher)

    # The replayed log is already in the mailbox when the child is back; a system message is
    # answered only after every message ahead of it, and each handler works inline.
    for _ <- 1..2, do: :sys.get_state(dispatcher, @barrier_timeout_ms)
    :ok
  end

  defp flush_starts() do
    receive do
      {:run_supervisor_start, _run_id, _opts} -> flush_starts()
    after
      0 -> :ok
    end
  end

  # Every `RunSupervisor` start option list recorded for `run_id` since the restart. Handlers run
  # inline in the Dispatcher and `restart_service!/0` returns only after it has handled the whole
  # replay, so every start is already in the mailbox.
  defp starts(run_id), do: collect_starts(run_id, [])

  defp collect_starts(run_id, acc) do
    receive do
      {:run_supervisor_start, ^run_id, opts} -> collect_starts(run_id, [opts | acc])
      {:run_supervisor_start, _other, _opts} -> collect_starts(run_id, acc)
    after
      0 -> acc |> Enum.reverse() |> Enum.uniq()
    end
  end

  # -- fixtures -----------------------------------------------------------------------------

  # The shipped test catalog has only a one-phase workflow, and a boundary between phases
  # needs several, so the task is created and then approved with its own three-phase
  # snapshot (the `task.approve` payload carries the snapshot a run is started from). The
  # Dispatcher admits the run and "starts" it (the recorder), fresh.
  @phases [%{"name" => "plan"}, %{"name" => "build"}, %{"name" => "verify"}]

  defp submit!(project) do
    task_id = "task-#{System.unique_integer([:positive])}"
    run_id = UniqueIds.unique_run_id("boundary")

    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        command_id: "c-#{System.unique_integer([:positive])}",
        aggregate_id: "task:#{task_id}",
        type: "task.create",
        payload: %{
          task_id: task_id,
          project_id: project,
          task_type: "implement",
          title: "t",
          prompt: "p",
          provider_tracked: false
        }
      })

    {:ok, _} =
      CommandGateway.dispatch_system(%{
        command_id: "a-#{System.unique_integer([:positive])}",
        aggregate_id: "task:#{task_id}",
        type: "task.approve",
        payload: %{
          task_id: task_id,
          approved_by: "test",
          approval_id: "approval-#{run_id}",
          run_id: run_id,
          approved_at: DateTime.to_iso8601(DateTime.utc_now()),
          workflow_snapshot: %{"phases" => @phases}
        }
      })

    assert_receive {:run_supervisor_start, ^run_id, []}, 10_000
    %{run_id: run_id, task_id: task_id, total: length(@phases)}
  end

  defp start_phase!(run_id, index) do
    phase_id = Identity.phase_id(run_id, index)

    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "phase.start",
        command_id: Identity.phase_start_command_id(run_id, index),
        aggregate_id: "phase:#{run_id}:#{phase_id}",
        payload: %{
          run_id: run_id,
          phase_id: phase_id,
          index: index,
          name: "phase-#{index}",
          attempt: 1,
          artifact_template: %{}
        }
      })
  end

  defp complete_phase!(run_id, index) do
    start_phase!(run_id, index)
    phase_id = Identity.phase_id(run_id, index)

    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "phase.complete",
        command_id: Identity.phase_complete_command_id(run_id, index),
        aggregate_id: "phase:#{run_id}:#{phase_id}",
        payload: %{
          run_id: run_id,
          phase_id: phase_id,
          index: index,
          artifact_path: "artifacts/p#{index}.md",
          artifact_sha256: String.duplicate("a", 64),
          artifact_bytes: 10 + index
        }
      })
  end

  defp retry_phase!(run_id, index) do
    phase_id = Identity.phase_id(run_id, index)

    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "phase.retry",
        command_id: "test:retry:#{phase_id}",
        aggregate_id: "phase:#{run_id}:#{phase_id}",
        payload: %{run_id: run_id, phase_id: phase_id, index: index, reason: "resumed"}
      })
  end

  defp pause!(run_id) do
    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run.pause",
        command_id: "test:pause:#{run_id}:#{System.unique_integer([:positive])}",
        aggregate_id: "run:#{run_id}",
        payload: %{run_id: run_id, reason: "awaiting_human"}
      })
  end

  # The human's answer: the approval deliverer resumes a paused run exactly like this.
  defp resume!(run_id) do
    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run.resume",
        command_id: "test:resume:#{run_id}:#{System.unique_integer([:positive])}",
        aggregate_id: "run:#{run_id}",
        payload: %{run_id: run_id, reason: "approval_decided"}
      })
  end

  defp cancel!(run_id) do
    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run.cancel",
        command_id: "test:cancel:#{run_id}",
        aggregate_id: "run:#{run_id}",
        payload: %{run_id: run_id, reason: "test"}
      })
  end

  # What a restart must reconstruct: the run's status and, per phase, its status, attempt and
  # artifact reference.
  defp snapshot(run_id) do
    run = ProjectionStore.run(run_id)

    phases =
      for phase <- ProjectionStore.phases_for_run(run_id) do
        %{
          index: phase.index,
          status: phase.status,
          attempt: phase.attempt,
          artifact: Map.get(phase, :artifact)
        }
      end

    %{run: %{status: run.status, terminal?: run.terminal?}, phases: phases}
  end
end
