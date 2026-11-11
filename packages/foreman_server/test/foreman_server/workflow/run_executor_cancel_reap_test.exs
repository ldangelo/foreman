defmodule ForemanServer.Workflow.RunExecutorCancelReapTest do
  @moduledoc """
  foreman-zmhzw. `run.cancel` / `thread stop` stop the agent through the harness
  (`RunControl.cancel_agent/1`), but the tool processes the agent started run in sessions of their
  own: a signal to the agent's process group never reaches them, so they outlived the cancelled run
  as orphans (ppid 1) in its worktree.

  The agent here is a REAL harness run (pi adapter, `fake_agent.sh` under erlexec) with a real tool
  process in a session of its own, cancelled the way the Dispatcher cancels it, and the executor's
  own cancel exits are driven with the real `RunControl` intent.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.JidoHarness.Driver
  alias ForemanServer.CommandGateway
  alias ForemanServer.ProjectionStore
  alias ForemanServer.RunControl
  alias ForemanServer.TestSupport.CoordinatorHelpers, as: H
  alias ForemanServer.TestSupport.DispatcherRestart
  alias ForemanServer.TestSupport.RunSlotsReset
  alias ForemanServer.TestSupport.StrayAgent
  alias ForemanServer.Workflow.BootReconciliation
  alias ForemanServer.Workflow.RunExecutor
  alias ForemanServer.Workflow.RunSupervisor

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    run_id = "run-cancel-reap-#{System.unique_integer([:positive])}"
    on_exit(fn -> RunControl.clear(run_id) end)

    # The agent ignores SIGINT: after the cancel it keeps running until the harness escalates to
    # SIGTERM, which is the window the executor has to wait out.
    StrayAgent.tight_grace!(600)

    %{
      run_id: run_id,
      # The executor state at the exits under test: every phase completed, one run worktree.
      state: %{
        run_id: run_id,
        task: %{task_id: run_id},
        status: :in_progress,
        completed: [0],
        phase_specs: [%{}],
        run_worktree: %{worktree_path: dir, cleanup: :never}
      }
    }
  end

  # What the Dispatcher does on `RunCancelled`: record the intent, cancel the harness run.
  defp operator_cancels(run_id, harness_run_id) do
    :ok = RunControl.register_agent(run_id, harness_run_id)
    :ok = RunControl.request(run_id, :cancel)
    assert :ok = RunControl.cancel_agent(run_id)
  end

  test "a cancel after the last phase waits for the stopping agent, then sweeps its tool process",
       %{tmp_dir: dir, run_id: run_id, state: state} do
    # The harness's own SIGTERM escalation is parked far out of reach: the "agent still stopping"
    # window must not be a wall-clock race against the two `ps` calls below (a loaded host stretched
    # them past the 600ms grace, the harness killed the agent first, and `alive?` read false). The
    # test ends the window itself, by signalling the agent once it has looked at it.
    StrayAgent.tight_grace!(60_000)
    %{run_id: harness_run_id, agent_os_pid: agent, stray_pid: stray} = StrayAgent.start!(dir)

    operator_cancels(run_id, harness_run_id)

    # The harness has signalled the agent and reports the run cancelled; the agent is still alive,
    # so its tool process still has a live parent and is no orphan yet.
    assert StrayAgent.alive?(agent)
    assert StrayAgent.ppid(stray) == agent

    # The executor is about to wait for the agent; the SIGTERM that stops it arrives while it waits.
    Task.start_link(fn ->
      Process.sleep(200)
      StrayAgent.terminate!(agent)
    end)

    assert {:stop, :normal, %{status: :cancelled}} = RunExecutor.__finish_phases_for_test__(state)

    refute StrayAgent.alive?(agent)
    refute StrayAgent.alive?(stray), "the cancelled run's tool process outlived it"
  end

  test "a cancel before the next phase starts sweeps the worktree the same way",
       %{tmp_dir: dir, run_id: run_id, state: state} do
    %{run_id: harness_run_id, agent_os_pid: agent, stray_pid: stray} = StrayAgent.start!(dir)

    operator_cancels(run_id, harness_run_id)

    # Phase 2 never starts: the engine's between-phases intent check stops the run.
    state =
      Map.merge(state, %{
        completed: [],
        resume_from: 0,
        worktree_spec: nil,
        plan_context: %{"project_root" => dir},
        run_base_branch: {:ok, "main"},
        phase_specs: [%{name: "never-runs", action: :command, command: "/skill:never-runs"}]
      })

    assert {:stop, :normal, %{status: :cancelled}} = RunExecutor.__run_phases_for_test__(state)

    refute StrayAgent.alive?(agent)
    refute StrayAgent.alive?(stray), "the cancelled run's tool process outlived it"
  end

  test "a cancel whose agent has already exited still sweeps the orphaned tool process",
       %{tmp_dir: dir, run_id: run_id, state: state} do
    # SIGINT kills this agent at once; nothing is left to wait for, only the orphan to sweep.
    %{run_id: harness_run_id, agent_os_pid: agent, stray_pid: stray} =
      StrayAgent.start!(dir, %{"FAKE_AGENT_IGNORE_INT" => nil})

    operator_cancels(run_id, harness_run_id)
    StrayAgent.await!("the agent to exit", fn -> not StrayAgent.alive?(agent) end)
    StrayAgent.await!("the tool process to be orphaned", fn -> StrayAgent.ppid(stray) == 1 end)

    assert {:stop, :normal, %{status: :cancelled}} = RunExecutor.__finish_phases_for_test__(state)

    refute StrayAgent.alive?(stray), "the cancelled run's tool process outlived it"
  end

  test "a cancel leaves a process outside the run worktree alone",
       %{tmp_dir: dir, run_id: run_id, state: state} do
    mine = Path.join(dir, "mine")
    other = Path.join(dir, "mine-other")
    File.mkdir_p!(mine)
    File.mkdir_p!(other)

    %{run_id: harness_run_id} = StrayAgent.start!(mine)
    %{agent_os_pid: bystander_agent, stray_pid: bystander} = StrayAgent.start!(other)
    operator_cancels(run_id, harness_run_id)

    state = put_in(state.run_worktree.worktree_path, mine)
    assert {:stop, :normal, %{status: :cancelled}} = RunExecutor.__finish_phases_for_test__(state)

    # Another run's agent and its tool process (a live parent, and another worktree) are untouched.
    assert StrayAgent.alive?(bystander_agent)
    assert StrayAgent.alive?(bystander)
  end

  test "a cancel with no agent and no worktree is a plain stop", %{run_id: run_id, state: state} do
    :ok = RunControl.request(run_id, :cancel)
    state = Map.delete(state, :run_worktree)

    assert {:stop, :normal, %{status: :cancelled}} = RunExecutor.__finish_phases_for_test__(state)
  end

  test "the cancel's escalation and the sweep after Driver.await_exit are observable",
       %{tmp_dir: dir, run_id: run_id, state: state} do
    # SIGINT is ignored by this agent and the harness's SIGTERM step is a second away; the sweep
    # must not start before the agent has gone, and must then name the tool process it killed.
    StrayAgent.tight_grace!(1_000)
    %{run_id: harness_run_id, agent_os_pid: agent, stray_pid: stray} = StrayAgent.start!(dir)

    operator_cancels(run_id, harness_run_id)

    # Right after the cancel nothing is stopped: the agent is alive and its tool process still has
    # a live parent, so nothing is an orphan for the reaper to find yet.
    assert StrayAgent.alive?(agent)
    assert StrayAgent.alive?(stray)
    assert StrayAgent.ppid(stray) == agent

    log =
      ExUnit.CaptureLog.capture_log([level: :warning], fn ->
        assert {:stop, :normal, %{status: :cancelled}} =
                 RunExecutor.__finish_phases_for_test__(state)
      end)

    refute StrayAgent.alive?(agent)
    refute StrayAgent.alive?(stray), "the cancelled run's tool process outlived it"
    assert :ok = Driver.await_exit(harness_run_id, 1_000)

    assert log =~ ~r/OrphanReaper: terminating \d+ [^:]*: .*\{#{stray},/s,
           "the sweep did not name the tool process #{stray}: #{log}"
  end

  describe "a cancelled run across a server restart" do
    setup do
      # Restore the app-level Dispatcher (subscribed, projection reset) and free the global slots:
      # a full slot would queue the run instead of admitting it.
      DispatcherRestart.restart!()
      RunSlotsReset.reset!()

      {:ok, _} =
        CommandGateway.dispatch_system(%{
          type: "run_slots.acquire",
          command_id: "test:cancel-restart-init:#{System.unique_integer([:positive])}",
          aggregate_id: "run_slots:global",
          payload: %{
            run_id: "cancel-restart-init-#{System.unique_integer([:positive])}",
            capacity: 100
          }
        })

      # The run supervisor is the one seam mocked: a start here is the observable "a phase would be
      # launched". Everything else (aggregates, projection, admission, Dispatcher) is real.
      :meck.new(RunSupervisor, [:no_link])
      test = self()

      :meck.expect(RunSupervisor, :start_run, fn run_id, _task, opts ->
        send(test, {:run_supervisor_start, run_id, opts})
        {:ok, :child}
      end)

      on_exit(fn ->
        if :meck.validate(RunSupervisor), do: :meck.unload(RunSupervisor)
        DispatcherRestart.restart!()
      end)

      H.subscribe!()
      project = H.register_project(System.tmp_dir!(), config: %{})
      {:ok, project: project}
    end

    defp submit_task!(project) do
      task_id = "task-#{System.unique_integer([:positive])}"

      assert {:ok, %{"payload" => %{"run_id" => run_id}}} =
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
                   provider_tracked: false,
                   auto_approve: true
                 }
               })

      {task_id, run_id}
    end

    # A real restart of the Dispatcher WITHOUT resetting the projection: `init/1` replays the whole
    # event log into the new process, which is what a server boot does. `DispatcherRestart.restart!/0`
    # resets the projection first, so it cannot be used for the restart itself.
    defp restart_dispatcher_keeping_log! do
      app = ForemanServer.Application
      dispatcher = ForemanServer.Workflow.Dispatcher
      :ok = Supervisor.terminate_child(app, dispatcher)
      {:ok, pid} = Supervisor.restart_child(app, dispatcher)
      drain_dispatcher!(pid, 100)
    end

    # The replay is queued before `init/1` returns; a suspended Dispatcher handles nothing, so an
    # empty mailbox seen while suspended (and a subscribed state) means the replay is done.
    defp drain_dispatcher!(_pid, 0), do: flunk("the Dispatcher never finished its replay")

    defp drain_dispatcher!(pid, tries) do
      :ok = :sys.suspend(pid, 30_000)

      {queued, state} =
        try do
          {:message_queue_len, queued} = Process.info(pid, :message_queue_len)
          {queued, :sys.get_state(pid, 30_000)}
        after
          :ok = :sys.resume(pid, 30_000)
        end

      if queued == 0 and Map.get(state, :subscriber) != :retrying do
        :ok
      else
        Process.sleep(20)
        drain_dispatcher!(pid, tries - 1)
      end
    end

    defp flush_starts(run_id) do
      receive do
        {:run_supervisor_start, ^run_id, _opts} -> flush_starts(run_id)
      after
        0 -> :ok
      end
    end

    test "stays cancelled and no phase is launched by the replay or by boot reconciliation",
         %{project: project} do
      {_task_id, run_id} = submit_task!(project)
      assert_receive {:run_supervisor_start, ^run_id, _opts}, 10_000

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cancel-#{System.unique_integer([:positive])}",
                 aggregate_id: "run:#{run_id}",
                 type: "run.cancel",
                 payload: %{run_id: run_id}
               })

      assert %{status: "cancelled", terminal?: true} = before = ProjectionStore.run(run_id)

      # Everything the live Dispatcher did before the restart (the run's own start, and any
      # duplicate dispatch of its task) is behind us: only a start after the restart counts.
      _ = :sys.get_state(ForemanServer.Workflow.Dispatcher)
      flush_starts(run_id)

      restart_dispatcher_keeping_log!()
      assert :ok = BootReconciliation.reconcile()

      refute_received {:run_supervisor_start, ^run_id, _opts}
      assert %{status: "cancelled", terminal?: true} = after_restart = ProjectionStore.run(run_id)
      assert after_restart.last_sequence == before.last_sequence
      assert ProjectionStore.phases_for_run(run_id) == []
    end
  end
end
