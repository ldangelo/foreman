defmodule ForemanServer.Agents.OperatorQuestionDispatcherTest do
  @moduledoc """
  Tests for `ForemanServer.Agents.OperatorQuestionDispatcher` — the
  JSI-T007 dispatcher that hands operator signals off to
  `ForemanServer.Inbox.SharedInbox.ingest/2` (TRD-2026-4212be7e,
  JSI-T006 + JSI-T007).

  These tests start the Poller + DedupeTable explicitly (mirroring
  the `poller_test.exs` pattern) so the dispatcher is exercised
  end-to-end through to the inbox without booting the full Foreman
  application.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Agents.OperatorQuestionDispatcher
  alias ForemanServer.Agents.OperatorQuestionSource
  alias ForemanServer.Inbox.{DedupeTable, InboxItemStarted, Poller}

  setup_all do
    {:ok, _} = Application.ensure_all_started(:jido_signal)

    # Start the Poller + DedupeTable explicitly. Mirrors
    # `test/foreman_server/inbox/poller_test.exs` — those tests do
    # NOT boot the full Foreman application (which fails in this
    # environment because :erlexec can't start) but still need the
    # inbox pipeline live.
    case Process.whereis(DedupeTable) do
      nil -> {:ok, _} = DedupeTable.start_link([])
      _ -> :ok
    end

    case Process.whereis(Poller) do
      nil -> {:ok, _} = Poller.start_link([])
      _ -> :ok
    end

    :ok
  end

  setup do
    # Clear the dedupe table before each test so :started is the
    # first-call result (matches the existing inbox test pattern).
    DedupeTable.clear()
    Application.put_env(:foreman_server, :inbox_dedupe_window_seconds, 60)
    :ok
  end

  describe "dispatch/1 with a Jido.Signal" do
    test "calls SharedInbox.ingest/2 and returns {:ok, :started, _} for a new question" do
      signal =
        Jido.Signal.new!(%{
          id: "evt-op-1",
          source: "operator.ui",
          type: "com.foreman.operator.question",
          specversion: "1.0.2",
          data: %{
            "question_id" => "q-42",
            "question" => "what should I do?",
            "agent_id" => "agent-7"
          }
        })

      assert {:ok, :started, %InboxItemStarted{} = item} =
               OperatorQuestionDispatcher.dispatch(signal)

      assert item.correlation_id == "q-42"
      assert item.source == OperatorQuestionSource
    end

    test "returns {:ok, :deduped, _} for a repeated question" do
      signal =
        Jido.Signal.new!(%{
          id: "evt-op-2",
          source: "operator.ui",
          type: "com.foreman.operator.question",
          specversion: "1.0.2",
          data: %{
            "question_id" => "q-43",
            "question" => "another one",
            "agent_id" => "agent-8"
          }
        })

      assert {:ok, :started, _} = OperatorQuestionDispatcher.dispatch(signal)
      assert {:ok, :deduped, _} = OperatorQuestionDispatcher.dispatch(signal)
    end

    test "returns {:error, :no_correlation_id} for data without question_id or agent_id" do
      signal =
        Jido.Signal.new!(%{
          id: "evt-op-3",
          source: "operator.ui",
          type: "com.foreman.operator.question",
          specversion: "1.0.2",
          data: %{"foo" => "bar"}
        })

      assert {:error, :no_correlation_id} =
               OperatorQuestionDispatcher.dispatch(signal)
    end
  end

  describe "OperatorQuestionSource.correlation_id/1" do
    test "extracts question_id from the signal data" do
      assert "q-42" ==
               OperatorQuestionSource.correlation_id(%{
                 "question_id" => "q-42",
                 "agent_id" => "agent-7"
               })
    end

    test "falls back to agent_id when question_id is missing" do
      assert "agent-7" ==
               OperatorQuestionSource.correlation_id(%{
                 "agent_id" => "agent-7"
               })
    end

    test "returns nil for data without question_id or agent_id" do
      assert is_nil(OperatorQuestionSource.correlation_id(%{"foo" => "bar"}))
    end
  end
end
