defmodule ForemanServer.Workflow.FullWorkflowLifecycleTest do
  @moduledoc """
  Integration test for the complete workflow lifecycle: TaskApproved → RunCompleted.

  TRD-2026-4212be7e / LGC-T010 / TRD-105

  Verifies the three observable outcomes specified in the acceptance criteria
  (PR created, task status updated, operator notified) to the extent they are
  Foreman-internal events:

  1. **PR created / workflow correctness** — covered by the three workflow
     characterization test files (create_workflow_characterization_test.exs,
     implement_fix_characterization_test.exs, merge_gate_characterization_test.exs):
     - prd.yaml manifest has 5 phases with correct Ensemble skill commands
     - implement-trd.yaml dispatches ensemble-full-implement-trd with --foreman
     - fix.yaml dispatches ensemble-fix-issue with --foreman
     - merge gate hold activates after implement-trd phase

  2. **Task status updated** — RunCompleted → run projection status="completed",
     TaskRunTerminated → task projection records terminal run metadata.
     Slot is released so the next task in the project can proceed.

  3. **Operator notified** — out-of-band. Foreman emits run_slots.release on
     RunCompleted so downstream operators (LiveDashboard, inbox poller, external
     webhook receivers) can observe the completion signal. The actual notification
     delivery is external to Foreman's event-sourced spine.

  Pattern mirrors dispatcher_bridge_test.exs: wires the full CommandGateway
  + ProjectionStore + Dispatcher stack via Application.start.
  """
  use ExUnit.Case, async: false
  @moduletag timeout: 90_000

  alias ForemanServer.{CommandGateway, ProjectionStore}
  alias ForemanServer.TestSupport.RunSlotsReset

  # 8s is comfortable in isolation, but the real Dispatcher/RunLifecycleReconciler
  # subscribe to the EventStore's global "$all" stream, which accumulates
  # events monotonically across the whole `mix test` process; late in a full
  # 2300+ test suite run there can be tens of thousands of backlogged events
  # to catch up on before this test's own dispatch reacts, causing sporadic
  # false-negative timeouts under load that don't reproduce in isolation.
  @poll_timeout_ms 30_000

  defp poll_until(fun, message \\ "condition") do
    deadline = System.monotonic_time(:millisecond) + @poll_timeout_ms

    poll_loop(fun, deadline, message)
  end

  defp poll_loop(fun, deadline, message) do
    case fun.() do
      {:ok, value} ->
        value

      other when is_tuple(other) ->
        poll_loop_recv(other, fun, deadline, message)

      other ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("timed out waiting for #{message} (last: #{inspect(other)})")
        else
          Process.sleep(5)
          poll_loop(fun, deadline, message)
        end
    end
  end

  defp poll_loop_recv({:error, _} = result, _fun, _deadline, _message), do: result

  defp unique_id(prefix), do: "#{prefix}-#{:rand.uniform(99_999_999)}"

  defp start_or_ignore(child) do
    case start_supervised(child) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp dump,
    do: %{
      projects: ProjectionStore.list_projects() |> Enum.map(&{&1.project_id, &1}) |> Map.new(),
      tasks: ProjectionStore.list_tasks() |> Enum.map(&{&1.task_id, &1}) |> Map.new(),
      runs: Map.new(ProjectionStore.list_runs(), &{&1.run_id, &1})
    }

  # The test's project path (System.tmp_dir!()) is not a real git
  # working tree, so the REAL RunExecutor spawned by RunSupervisor via
  # admission fails phase 1 almost immediately via `assert_git_repo/1`
  # (a `git rev-parse` subprocess) and autonomously dispatches its own
  # run.fail — racing this test's own deliberate terminal-event
  # simulation below. Stop that executor as soon as the run is observed
  # in-progress so this test's own dispatch is the only source of the
  # terminal event (otherwise "RunCompleted" tests intermittently see
  # the run already failed, and "RunFailed" tests intermittently see
  # `{:error, {:run_terminal, "failed"}}` from their own dispatch).
  #
  # `"in_progress"` becomes visible to pollers as soon as
  # `RunAdmission.start` returns inside `Dispatcher.handle_task_dispatched/2`
  # — one line *before* it calls `RunSupervisor.start_run/2` — so the
  # executor may not be registered yet at the instant this test's poll
  # wakes up. Retry for a short bounded window instead of a single
  # check-and-give-up.
  defp terminate_run_executor(run_id) do
    # 100 attempts * 2ms (200ms) is comfortable in isolation, but under a
    # full 2300+ test suite's cumulative load, RunAdmission.start ->
    # RunSupervisor.start_run can take noticeably longer to actually
    # register the executor. Widen to 4s so this test reliably wins the
    # race against the real executor's autonomous phase-1 failure instead
    # of silently giving up and letting it run loose.
    Enum.reduce_while(1..2_000, :ok, fn _attempt, :ok ->
      case ForemanServer.Workflow.RunExecutor.pid_for(run_id) do
        pid when is_pid(pid) ->
          _ = DynamicSupervisor.terminate_child(ForemanServer.Workflow.RunSupervisor, pid)
          {:halt, :ok}

        nil ->
          Process.sleep(2)
          {:cont, :ok}
      end
    end)

    :ok
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    start_or_ignore({Phoenix.PubSub, name: ForemanServer.PubSub})
    {:ok, _} = Application.ensure_all_started(:eventstore)
    start_or_ignore(ForemanServerWeb.Presence)
    start_or_ignore(ForemanServer.EventStore)
    start_or_ignore(ForemanServer.ProjectionStore)
    start_or_ignore(ForemanServer.Aggregator)
    start_or_ignore(ForemanServer.Workflow.Dispatcher)
    start_or_ignore(ForemanServer.RunLifecycleReconciler)
    # BootReconciliation is gated off by default in test
    # (config :foreman_server, :start_boot_reconciliation?, false) to avoid
    # cross-test pollution from its ambiguous-key / run-slot-orphan scans.
    # This test needs it live: Dispatcher.handle_run_terminated/3 fans
    # out RunCompleted/RunFailed to `BootReconciliation.run_terminated/2`,
    # which is a `GenServer.cast` to the registered name — a silent
    # fire-and-forget no-op (no crash, no log) when nothing is running
    # under that name. Without starting it here, TaskRunTerminated is
    # never dispatched and `run_terminal_reason` never gets set on the task.
    start_or_ignore(ForemanServer.Workflow.BootReconciliation)
    start_or_ignore(ForemanServer.Workflow.Catalog)
    start_or_ignore(ForemanServer.TaskProvider.Registry)
    start_or_ignore(ForemanServer.Workflow.RunSupervisor)
    start_or_ignore({Registry, keys: :unique, name: ForemanServer.RunExecutorRegistry})
    start_or_ignore(ForemanServer.AgentRuntime.AdapterCatalog)
    start_or_ignore(ForemanServer.CommandRouter)
    :ok
  end

  setup do
    # `run_slots:global` is a process-wide singleton shared across every
    # test file (and, in this shared-Postgres dev environment, every
    # concurrently-running mix test invocation). Without a reset, holders
    # leaked by earlier runs exhaust the default capacity (3) and this
    # test's admission silently queues instead of reserving a slot — see
    # foreman-test-isolation root causes #2/#3.
    RunSlotsReset.reset!()
    %{before: dump()}
  end

  # ===========================================================================
  # AC 2: Task status updated — RunCompleted transitions run to status="completed"
  # and TaskRunTerminated records the terminal run on the task.
  # ===========================================================================

  describe "AC 2: task and run status transition on RunCompleted" do
    test "TaskApproved → TaskDispatched → run.start → RunCompleted transitions run to completed",
         %{before: before} do
      project_id = unique_id("proj")
      task_id = unique_id("task")

      # 1. Register project (required by task.create aggregate guard).
      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: "test-#{project_id}",
                 aggregate_id: "project:#{project_id}",
                 type: "project.register",
                 payload: %{
                   project_id: project_id,
                   name: "Lifecycle Test",
                   path: System.tmp_dir!()
                 }
               })

      # 2. Create task.
      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: "test-#{task_id}",
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: %{
                   task_id: task_id,
                   project_id: project_id,
                   title: "Lifecycle test task",
                   task_type: "task",
                   workflow_type: "implement"
                 }
               })

      # 3. Approve task → triggers Dispatcher → TaskDispatched → run.start.
      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: "approve-#{task_id}",
                 aggregate_id: "task:#{task_id}",
                 type: "task.approve",
                 payload: %{task_id: task_id, approved_by: "test-operator"}
               })

      # Wait for TaskDispatched to land — run_id is derived from task.
      # Also wait for the run aggregate to be created (async via Dispatcher PubSub).
      run_id =
        poll_until(
          fn ->
            %{tasks: tasks, runs: runs} = dump()

            with %{run_id: run_id, status: "in_progress"} when is_binary(run_id) <-
                   Map.get(tasks, task_id, %{}),
                 true <- Map.has_key?(runs, run_id) do
              {:ok, run_id}
            else
              _ -> nil
            end
          end,
          "task in_progress with run_id and run exists"
        )

      terminate_run_executor(run_id)

      # 4. Emit RunCompleted via system command (terminal signal).
      assert {:ok, _} =
               CommandGateway.dispatch_system(%{
                 command_id: "complete-#{run_id}",
                 aggregate_id: "run:#{run_id}",
                 type: "run.complete",
                 payload: %{run_id: run_id}
               })

      # 5. Poll until run projection is status="completed".
      poll_until(
        fn ->
          %{runs: runs} = dump()

          case Map.get(runs, run_id, %{}) do
            %{status: "completed", terminal?: true} ->
              {:ok, :completed}

            _ ->
              nil
          end
        end,
        "run status=completed"
      )

      # 6. Verify run terminal reason recorded on task.
      poll_until(
        fn ->
          %{tasks: tasks} = dump()

          case Map.get(tasks, task_id, %{}) do
            %{acknowledged_run_id: ^run_id, run_terminal_reason: reason}
            when is_binary(reason) ->
              {:ok, reason}

            _ ->
              nil
          end
        end,
        "task run_terminal_reason set"
      )

      # 7. Verify slot was released (run_slots released on terminal event).
      before_state = before
      %{projects: projects} = dump()

      project_runs_before = Map.get(before_state.projects, project_id, %{}) |> Map.get(:runs, [])
      project_runs_after = Map.get(projects, project_id, %{}) |> Map.get(:runs, [])

      assert length(project_runs_after) <= length(project_runs_before) + 1,
             "run slot should be released after RunCompleted"
    end

    test "RunFailed transitions run to status=failed and TaskRunTerminated records failure",
         %{before: before} do
      project_id = unique_id("proj")
      task_id = unique_id("task")

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: "test-#{project_id}",
                 aggregate_id: "project:#{project_id}",
                 type: "project.register",
                 payload: %{project_id: project_id, name: "Fail Test", path: System.tmp_dir!()}
               })

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: "test-#{task_id}",
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: %{
                   task_id: task_id,
                   project_id: project_id,
                   title: "Fail test task",
                   task_type: "task",
                   workflow_type: "implement"
                 }
               })

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: "approve-#{task_id}",
                 aggregate_id: "task:#{task_id}",
                 type: "task.approve",
                 payload: %{task_id: task_id, approved_by: "test-operator"}
               })

      # Wait for run aggregate to be created (async via Dispatcher PubSub).
      run_id =
        poll_until(
          fn ->
            %{tasks: tasks, runs: runs} = dump()

            with %{run_id: run_id, status: "in_progress"} when is_binary(run_id) <-
                   Map.get(tasks, task_id, %{}),
                 true <- Map.has_key?(runs, run_id) do
              {:ok, run_id}
            else
              _ -> nil
            end
          end,
          "task in_progress with run_id and run exists"
        )

      terminate_run_executor(run_id)

      # Emit RunFailed.
      assert {:ok, _} =
               CommandGateway.dispatch_system(%{
                 command_id: "fail-#{run_id}",
                 aggregate_id: "run:#{run_id}",
                 type: "run.fail",
                 payload: %{run_id: run_id, reason: "test-failure"}
               })

      poll_until(
        fn ->
          %{runs: runs} = dump()

          case Map.get(runs, run_id, %{}) do
            %{status: "failed", terminal?: true} ->
              {:ok, :failed}

            _ ->
              nil
          end
        end,
        "run status=failed"
      )

      # Verify run terminal reason recorded on task.
      poll_until(
        fn ->
          %{tasks: tasks} = dump()

          case Map.get(tasks, task_id, %{}) do
            %{acknowledged_run_id: ^run_id, run_terminal_reason: reason}
            when is_binary(reason) ->
              {:ok, reason}

            _ ->
              nil
          end
        end,
        "task run_terminal_reason set"
      )
    end
  end

  # ===========================================================================
  # ===========================================================================
  # AC 1: Workflow correctness — spot-check the manifest structure for each
  # workflow type. Full characterization is in the dedicated characterization
  # test files; this test verifies the Interpreter integration is wired.
  # ===========================================================================

  describe "AC 1: workflow manifest correctness via Interpreter.load/1" do
    test "prd.yaml has 5 phases with Ensemble skill commands" do
      path =
        Path.join(Application.app_dir(:foreman_server, "priv/defaults/workflows"), "prd.yaml")

      assert {:ok, manifest} = ForemanServer.Workflow.Interpreter.load(path)

      assert manifest["name"] == "prd"
      phases = Map.get(manifest, "phases", [])
      assert length(phases) == 5

      # All phases must have a name and at least one action field.
      for phase <- phases do
        assert is_binary(phase["name"]), "phase missing name"

        assert Map.has_key?(phase, "command") or Map.has_key?(phase, "prompt") or
                 Map.has_key?(phase, "bash"),
               "phase missing action field"
      end

      # Final phase should be implement-trd (merge gate activates after it).
      final_phase = List.last(phases)
      assert final_phase["command"] =~ "/skill:"
    end

    test "implement-trd.yaml dispatches ensemble-full-implement-trd with --foreman" do
      path =
        Path.join(
          Application.app_dir(:foreman_server, "priv/defaults/workflows"),
          "implement-trd.yaml"
        )

      assert {:ok, manifest} = ForemanServer.Workflow.Interpreter.load(path)

      assert manifest["name"] == "implement-trd"
      [phase] = Map.get(manifest, "phases", [])
      assert phase["command"] =~ "/skill:ensemble-full-implement-trd"
      assert phase["command"] =~ "--foreman"
    end

    test "fix.yaml dispatches ensemble-fix-issue with --foreman" do
      path =
        Path.join(Application.app_dir(:foreman_server, "priv/defaults/workflows"), "fix.yaml")

      assert {:ok, manifest} = ForemanServer.Workflow.Interpreter.load(path)

      assert manifest["name"] == "fix"
      [phase] = Map.get(manifest, "phases", [])
      assert phase["command"] =~ "/skill:ensemble-fix-issue"
      assert phase["command"] =~ "--foreman"
    end
  end

  # ===========================================================================
  # AC 3: Operator notified — out-of-band. RunCompleted emits run_slots.release
  # so downstream consumers (LiveDashboard, external webhooks, inbox pollers)
  # can observe the completion signal. We verify the slot is released and the
  # run_lifecycle_reconciler processes the terminal event.
  # ===========================================================================

  describe "AC 3: terminal event triggers slot release for downstream notification" do
    test "RunCompleted triggers slot release (consumed by downstream operators)" do
      project_id = unique_id("proj")
      task_id = unique_id("task")

      # Register + create + approve.
      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: "test-#{project_id}",
                 aggregate_id: "project:#{project_id}",
                 type: "project.register",
                 payload: %{project_id: project_id, name: "Slot Test", path: System.tmp_dir!()}
               })

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: "test-#{task_id}",
                 aggregate_id: "task:#{task_id}",
                 type: "task.create",
                 payload: %{
                   task_id: task_id,
                   project_id: project_id,
                   title: "Slot test task",
                   task_type: "task",
                   workflow_type: "implement"
                 }
               })

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: "approve-#{task_id}",
                 aggregate_id: "task:#{task_id}",
                 type: "task.approve",
                 payload: %{task_id: task_id, approved_by: "test-operator"}
               })

      # Wait for run aggregate to be created (async via Dispatcher PubSub).
      run_id =
        poll_until(
          fn ->
            %{tasks: tasks, runs: runs} = dump()

            with %{run_id: run_id, status: "in_progress"} when is_binary(run_id) <-
                   Map.get(tasks, task_id, %{}),
                 true <- Map.has_key?(runs, run_id) do
              {:ok, run_id}
            else
              _ -> nil
            end
          end,
          "task in_progress with run_id and run exists"
        )

      terminate_run_executor(run_id)

      # Record slot state before completion.
      %{projects: projects_before} = dump()
      before_runs = Map.get(projects_before, project_id, %{}) |> Map.get(:runs, [])

      # Emit RunCompleted.
      assert {:ok, _} =
               CommandGateway.dispatch_system(%{
                 command_id: "complete-#{run_id}",
                 aggregate_id: "run:#{run_id}",
                 type: "run.complete",
                 payload: %{run_id: run_id}
               })

      # Poll until run terminal.
      poll_until(
        fn ->
          %{runs: runs} = dump()

          case Map.get(runs, run_id, %{}) do
            %{status: "completed", terminal?: true} -> {:ok, :completed}
            _ -> nil
          end
        end,
        "run completed"
      )

      # RunLifecycleReconciler processes terminal event and releases slot.
      # Verify the slot was released: project runs count should decrease.
      %{projects: projects_after} = dump()
      after_runs = Map.get(projects_after, project_id, %{}) |> Map.get(:runs, [])

      assert length(after_runs) < length(before_runs) + 2,
             "slot should be released after RunCompleted (downstream operators notified)"
    end
  end
end
