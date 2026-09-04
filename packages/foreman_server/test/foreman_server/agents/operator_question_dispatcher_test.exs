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

  # Meck helper — calls :meck.new/2 before :meck.expect so passthrough stubs
  # are established for all three modules before the test runs.
  defp meck_passthrough(module) do
    :meck.new(module, [:passthrough, :no_link])
  end

  defp meck_expect(module, fun, mock_fn) do
    :meck.expect(module, fun, mock_fn)
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:jido_signal)
    {:ok, _} = Application.ensure_all_started(:meck)
    # Start the Poller + DedupeTable + OperatorTimeout explicitly. Mirrors
    # `test/foreman_server/inbox/poller_test.exs` — those tests do
    # NOT boot the full Foreman application (which fails in this
    # environment because :erlexec can't start) but still need the
    # inbox pipeline and timeout scheduling live.
    case Process.whereis(DedupeTable) do
      nil ->
        {:ok, _} = DedupeTable.start_link(name: DedupeTable)
        :ok

      _pid ->
        :ok
    end

    case Process.whereis(Poller) do
      nil ->
        {:ok, _} = Poller.start_link(name: Poller)
        :ok

      _pid ->
        :ok
    end

    case Process.whereis(ForemanServer.Agents.OperatorTimeout) do
      nil ->
        {:ok, _} =
          ForemanServer.Agents.OperatorTimeout.start_link(
            name: ForemanServer.Agents.OperatorTimeout
          )

        :ok

      _pid ->
        :ok
    end

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

  describe "resolve_operator_timeout/1 — manifest-read path (TRD-027)" do
    setup do
      # Establish passthrough stubs so the real implementations remain callable
      # for any functions we don't explicitly mock (e.g. other ProjectionStore calls
      # in concurrently-running tests).
      meck_passthrough(ForemanServer.ProjectionStore)
      meck_passthrough(ForemanServer.Workflow.Catalog)
      meck_passthrough(ForemanServer.Agents.OperatorTimeout)

      # Mock ProjectionStore → returns a task whose workflow_snapshot names "implement"
      meck_expect(ForemanServer.ProjectionStore, :task_projection, fn "agent-manifest-123" ->
        %{workflow_snapshot: %{"workflow_name" => "implement"}}
      end)

      # Mock Catalog → returns a manifest declaring a 15-minute operator timeout
      meck_expect(ForemanServer.Workflow.Catalog, :load, fn "implement.yaml" ->
        {:ok, %{"name" => "implement", "operator_timeout_ms" => 900_000}}
      end)

      # Mock OperatorTimeout.schedule/3 → send captured timeout_ms to test process
      meck_expect(ForemanServer.Agents.OperatorTimeout, :schedule, fn
        question_id, agent_id, timeout_ms
        when question_id == "q-timeout-test" and agent_id == "agent-manifest-123" ->
          send(self(), {:captured_timeout_ms, timeout_ms})
          :ok
      end)

      on_exit(fn ->
        :meck.unload([
          ForemanServer.ProjectionStore,
          ForemanServer.Workflow.Catalog,
          ForemanServer.Agents.OperatorTimeout
        ])
      end)

      :ok
    end

    test "reads operator_timeout_ms from the workflow manifest and passes it to OperatorTimeout.schedule/3" do
      signal =
        Jido.Signal.new!(%{
          id: "evt-op-timeout",
          source: "operator.ui",
          type: "com.foreman.operator.question",
          specversion: "1.0.2",
          data: %{
            "question_id" => "q-timeout-test",
            "question" => "what should I do?",
            "agent_id" => "agent-manifest-123"
          }
        })

      assert {:ok, :started, _} = OperatorQuestionDispatcher.dispatch(signal)

      assert_receive {:captured_timeout_ms, 900_000},
                     1_000,
                     "OperatorTimeout.schedule/3 was not called with the manifest's operator_timeout_ms"
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
