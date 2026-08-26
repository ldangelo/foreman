defmodule ForemanServer.Agents.SignalJournalTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Agents.SignalJournal

  # SignalJournal is a supervised singleton (started by
  # ForemanServer.Application.maybe_signal_journal_child/0 whenever
  # :agent_runtime is enabled, which config/test.exs always is), so
  # tests must not start_link/0 their own instance — that collides
  # with `{:already_started, pid}`. Clear its shared ETS-backed state
  # before each test instead, so entries recorded by one test (or a
  # prior run order) never leak into another test's replay/0 count.
  setup do
    SignalJournal.clear()
    :ok
  end

  test "record and replay" do
    {:ok, id1} = SignalJournal.record("topic.a", %{x: 1})
    {:ok, id2} = SignalJournal.record("topic.b", %{y: 2})
    assert is_binary(id1)
    assert is_binary(id2)
    all = SignalJournal.replay()
    assert length(all) == 2
  end

  test "replay filtered by topic" do
    {:ok, _} = SignalJournal.record("topic.x", %{})
    {:ok, _} = SignalJournal.record("topic.y", %{})
    x_only = SignalJournal.replay("topic.x")
    assert length(x_only) == 1
  end
end
