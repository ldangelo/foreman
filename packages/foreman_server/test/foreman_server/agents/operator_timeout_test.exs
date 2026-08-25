defmodule ForemanServer.Agents.OperatorTimeoutTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Agents.OperatorTimeout

  # OperatorTimeout is not supervised in test env (config/test.exs sets
  # no :operator_timeout config, so Application.maybe_operator_timeout_child/0
  # starts nothing). Some other test file's setup_all (e.g.
  # operator_question_dispatcher_test.exs) may already have started and
  # leaked one under the registered name (its setup_all-owning process
  # exits normally, which doesn't cascade-kill a non-trapping linked
  # GenServer) — guard the start like that file already does, instead of
  # hard-matching {:ok, _pid} and colliding with {:already_started, pid}.
  setup_all do
    case Process.whereis(OperatorTimeout) do
      nil ->
        {:ok, _pid} = OperatorTimeout.start_link()
        :ok

      _pid ->
        :ok
    end
  end

  test "schedule and cancel" do
    assert :ok = OperatorTimeout.schedule("wf-1", "task-1", 60_000)
    assert :ok = OperatorTimeout.cancel("wf-1", "task-1")
  end

  test "cancel of unknown id is a no-op" do
    assert :ok = OperatorTimeout.cancel("wf-x", "task-x")
  end
end
