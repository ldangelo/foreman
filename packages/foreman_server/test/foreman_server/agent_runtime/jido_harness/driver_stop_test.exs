defmodule ForemanServer.AgentRuntime.JidoHarness.DriverStopTest do
  @moduledoc """
  `Driver.stop/2` cancels a harness run and waits until its agent is gone. A REAL harness run
  (pi adapter, `fake_agent.sh` under erlexec) whose agent ignores SIGINT, so `Run.cancel/1`
  reports the run cancelled at once while the agent is still alive and only goes away when the
  harness escalates to SIGTERM (`StrayAgent`).
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

  test "cancels the run and returns once its agent has exited", %{tmp_dir: dir} do
    %{run_id: run_id, agent_os_pid: agent} = StrayAgent.start!(dir)

    assert :ok = Driver.stop(run_id, 10_000)

    refute StrayAgent.alive?(agent)
    assert {:ok, %{status: :cancelled}} = Run.await(run_id, 1_000)
  end

  test "reports a timeout while the agent is still being stopped", %{tmp_dir: dir} do
    %{run_id: run_id, agent_os_pid: agent} = StrayAgent.start!(dir)

    assert {:error, :timeout} = Driver.stop(run_id, 20)

    assert StrayAgent.alive?(agent)
  end

  test "returns at once for a run that is already over", %{tmp_dir: dir} do
    %{run_id: run_id} = StrayAgent.start!(dir)
    assert :ok = Run.cancel(run_id)
    assert :ok = Driver.await_exit(run_id, 10_000)

    assert :ok = Driver.stop(run_id, 10_000)
  end

  test "returns at once for a run that never existed" do
    assert :ok = Driver.stop("run-that-never-existed", 10_000)
  end
end
