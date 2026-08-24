defmodule ForemanServer.Agents.SignalJournalTest do
  use ExUnit.Case, async: false

  test "record and replay" do
    {:ok, _pid} = ForemanServer.Agents.SignalJournal.start_link()
    {:ok, id1} = ForemanServer.Agents.SignalJournal.record("topic.a", %{x: 1})
    {:ok, id2} = ForemanServer.Agents.SignalJournal.record("topic.b", %{y: 2})
    assert is_binary(id1)
    assert is_binary(id2)
    all = ForemanServer.Agents.SignalJournal.replay()
    assert length(all) == 2
  end

  test "replay filtered by topic" do
    {:ok, _pid} = ForemanServer.Agents.SignalJournal.start_link()
    {:ok, _} = ForemanServer.Agents.SignalJournal.record("topic.x", %{})
    {:ok, _} = ForemanServer.Agents.SignalJournal.record("topic.y", %{})
    x_only = ForemanServer.Agents.SignalJournal.replay("topic.x")
    assert length(x_only) == 1
  end
end
