defmodule ForemanServer.Agents.OperatorTimeoutTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Agents.OperatorTimeout

  # OperatorTimeout is part of the application tree under test
  # (config/test.exs enables :operator_timeout), so it is already running.

  test "schedule and cancel" do
    assert :ok = OperatorTimeout.schedule("wf-1", "task-1", 60_000)
    assert :ok = OperatorTimeout.cancel("wf-1", "task-1")
  end

  test "cancel of unknown id is a no-op" do
    assert :ok = OperatorTimeout.cancel("wf-x", "task-x")
  end
end
