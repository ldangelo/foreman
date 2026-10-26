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

  alias ForemanServer.RunControl
  alias ForemanServer.TestSupport.StrayAgent
  alias ForemanServer.Workflow.RunExecutor

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
    %{run_id: harness_run_id, agent_os_pid: agent, stray_pid: stray} = StrayAgent.start!(dir)

    operator_cancels(run_id, harness_run_id)

    # The harness has signalled the agent and reports the run cancelled; the agent is still alive,
    # so its tool process still has a live parent and is no orphan yet.
    assert StrayAgent.alive?(agent)
    assert StrayAgent.ppid(stray) == agent

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
end
