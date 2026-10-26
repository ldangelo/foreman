defmodule ForemanServer.AgentRuntime.JidoHarness.DriverAwaitExitTest do
  @moduledoc """
  foreman-zmhzw. A REAL harness run (pi adapter, `fake_agent.sh` under erlexec). The agent ignores
  SIGINT, so `Run.cancel/1` reports the run cancelled at once while the agent is still alive and
  only goes away when the harness escalates to SIGTERM.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.JidoHarness.Driver
  alias ForemanServer.TestSupport.StrayAgent
  alias Jido.Harness.Run

  @moduletag :tmp_dir

  setup do
    StrayAgent.tight_grace!(1_000)
    :ok
  end

  test "returns only once the cancelled agent has exited", %{tmp_dir: dir} do
    %{run_id: run_id, agent_os_pid: agent} = StrayAgent.start!(dir)

    assert :ok = Run.cancel(run_id)
    # Cancelled as far as the run is concerned, but the agent ignored SIGINT and is still there.
    assert {:ok, %{status: :cancelled}} = Run.await(run_id, 1_000)
    assert StrayAgent.alive?(agent)

    assert :ok = Driver.await_exit(run_id, 10_000)

    refute StrayAgent.alive?(agent)
  end

  test "reports a timeout while the agent is still being stopped", %{tmp_dir: dir} do
    %{run_id: run_id, agent_os_pid: agent} = StrayAgent.start!(dir)
    assert :ok = Run.cancel(run_id)

    assert {:error, :timeout} = Driver.await_exit(run_id, 20)

    assert StrayAgent.alive?(agent)
  end

  test "returns at once for a run with no live process" do
    assert :ok = Driver.await_exit("run-that-never-existed", 10_000)
  end

  test "agent_os_pids/0 lists a running agent and drops it once it has exited", %{tmp_dir: dir} do
    %{run_id: run_id, agent_os_pid: agent} = StrayAgent.start!(dir)

    assert agent in Driver.agent_os_pids()

    assert :ok = Run.cancel(run_id)
    assert :ok = Driver.await_exit(run_id, 10_000)

    refute agent in Driver.agent_os_pids()
  end
end
