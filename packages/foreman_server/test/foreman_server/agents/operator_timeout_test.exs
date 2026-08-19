defmodule ForemanServer.Agents.OperatorTimeoutTest do
  use ExUnit.Case, async: false

  test "schedule and cancel" do
    {:ok, _pid} = ForemanServer.Agents.OperatorTimeout.start_link()
    assert :ok = ForemanServer.Agents.OperatorTimeout.schedule("wf-1", "task-1", 60_000)
    assert :ok = ForemanServer.Agents.OperatorTimeout.cancel("wf-1", "task-1")
  end

  test "cancel of unknown id is a no-op" do
    {:ok, _pid} = ForemanServer.Agents.OperatorTimeout.start_link()
    assert :ok = ForemanServer.Agents.OperatorTimeout.cancel("wf-x", "task-x")
  end
end
