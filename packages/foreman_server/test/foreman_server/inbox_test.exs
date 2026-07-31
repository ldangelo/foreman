defmodule ForemanServer.InboxItemTest do
  use ExUnit.Case, async: true

  alias ForemanServer.{Aggregate, Events.InboxItemStarted, Events.InboxItemDeduped}
  alias ForemanServer.Aggregates.InboxThread

  doctest InboxItemStarted
  doctest InboxItemDeduped

  # ─── from_payload ─────────────────────────────────────────────────────────

  describe "InboxItemStarted.from_payload/1" do
    test "atom keys" do
      payload = %{
        correlation_id: "corr-1",
        run_id: "run-from-payload-1",
        source: "attach-bridge",
        timestamp: ~U[2026-07-29T12:00:00Z],
        payload: %{"foo" => "bar"}
      }

      event = InboxItemStarted.from_payload(payload)
      assert event.correlation_id == "corr-1"
      assert event.source == "attach-bridge"
      assert event.timestamp == ~U[2026-07-29T12:00:00Z]
      assert event.payload == %{"foo" => "bar"}
    end

    test "string keys" do
      payload = %{
        "correlation_id" => "corr-2",
        "run_id" => "run-from-payload-2",
        "source" => "external-trigger",
        "timestamp" => "2026-07-29T12:00:00Z",
        "payload" => %{"baz" => 42}
      }

      event = InboxItemStarted.from_payload(payload)
      assert event.correlation_id == "corr-2"
      assert event.source == "external-trigger"
      assert event.timestamp == ~U[2026-07-29T12:00:00Z]
    end

    test "ISO8601 string timestamp normalised to DateTime" do
      payload = %{
        correlation_id: "corr-3",
        run_id: "run-from-payload-3",
        source: "test",
        timestamp: "2026-07-29T14:30:00Z"
      }

      event = InboxItemStarted.from_payload(payload)
      assert event.timestamp == ~U[2026-07-29T14:30:00Z]
    end

    test "payload defaults to %{} when absent" do
      payload = %{correlation_id: "corr-4", run_id: "run-from-payload-4", source: "test"}
      event = InboxItemStarted.from_payload(payload)
      assert event.payload == %{}
      assert event.timestamp != nil
    end

    test "missing correlation_id raises" do
      payload = %{source: "bridge"}

      assert_raise RuntimeError, ~r/correlation_id.*required/, fn ->
        InboxItemStarted.from_payload(payload)
      end
    end

    test "empty source raises" do
      payload = %{correlation_id: "corr-5", run_id: "run-from-payload-5", source: ""}

      assert_raise RuntimeError, ~r/source.*required/, fn ->
        InboxItemStarted.from_payload(payload)
      end
    end
  end

  describe "InboxItemDeduped.from_payload/1" do
    test "string keys and ISO8601 timestamp" do
      payload = %{
        "correlation_id" => "dedupe-1",
        "run_id" => "run-dedupe-1",
        "source" => "bridge",
        "timestamp" => "2026-07-29T09:00:00Z"
      }

      event = InboxItemDeduped.from_payload(payload)
      assert event.correlation_id == "dedupe-1"
      assert event.timestamp == ~U[2026-07-29T09:00:00Z]
    end
  end

  # ─── apply_event ──────────────────────────────────────────────────────────

  describe "apply_event — typed struct clauses" do
    setup do
      state = %InboxThread.State{messages: %{}, correlation_index: %{}}
      {:ok, state: state}
    end

    test "InboxItemStarted populates messages and correlation_index", %{state: state} do
      event = %InboxItemStarted{
        correlation_id: "corr-1",
        run_id: "test-run-1",
        source: "bridge",
        timestamp: ~U[2026-07-29T12:00:00Z],
        payload: %{"run_id" => "run-99"}
      }

      new_state = InboxThread.apply_event(state, event)
      assert is_map(new_state.messages["corr-1"])
      assert new_state.correlation_index["corr-1"] == ~U[2026-07-29T12:00:00Z]
    end
    test "InboxItemDeduped updates only correlation_index", %{state: state} do
      event = %InboxItemDeduped{
        correlation_id: "corr-1",
        run_id: "test-run-1",
        source: "bridge",
        timestamp: ~U[2026-07-29T12:00:00Z]
      }
      new_state = InboxThread.apply_event(state, event)
      assert new_state.messages == %{}
      assert new_state.correlation_index["corr-1"] == ~U[2026-07-29T12:00:00Z]
    end
    test "envelope-unwrapping: %Event{payload: %InboxItemStarted{}}", %{state: state} do
      inner = %InboxItemStarted{
        correlation_id: "corr-env",
        run_id: "test-run-env",
        source: "test",
        timestamp: ~U[2026-07-29T12:00:00Z],
        payload: %{}
      }

      envelope = %ForemanServer.Event{
        event_id: "evt-env",
        stream_id: "inbox:test",
        stream_version: 1,
        event_type: "InboxItemStarted",
        schema_version: 1,
        payload: inner,
        metadata: %{},
        occurred_at: ~U[2026-07-29T12:00:00Z],
        correlation_id: "corr-env"
      }

      new_state = InboxThread.apply_event(state, envelope)
      assert new_state.correlation_index["corr-env"] == ~U[2026-07-29T12:00:00Z]
    end
  end

  # ─── Aggregate.fold/2 with typed structs ──────────────────────────────────

  describe "Aggregate.fold/2 — typed struct replay" do
    test "typed struct payload reconstructed via EventCodec and envelope preserved" do
      {:ok, event} =
        ForemanServer.Event.new(
          %{
            stream_id: "inbox:test",
            event_type: "InboxItemStarted",
            payload:
              InboxItemStarted.from_payload(%{
                correlation_id: "fold-corr",
                run_id: "run-fold",
                source: "test",
                timestamp: ~U[2026-07-29T12:00:00Z],
                payload: %{"key" => "value"}
              })
          },
          1
        )

      final_state = Aggregate.fold(InboxThread, [event])

      assert final_state.correlation_index["fold-corr"] == ~U[2026-07-29T12:00:00Z]
      assert final_state.messages["fold-corr"][:source] == "test"
    end

    test "plain-map legacy payload passes through unchanged (backward compat)" do
      {:ok, event} =
        ForemanServer.Event.new(
          %{
            stream_id: "inbox:test",
            event_type: "InboxItemStarted",
            payload: %{
              "correlation_id" => "legacy-corr",
              "run_id" => "run-legacy",
              "source" => "legacy",
              "timestamp" => "2026-07-29T12:00:00Z"
            }
          },
          1
        )

      final_state = Aggregate.fold(InboxThread, [event])

      assert final_state.correlation_index["legacy-corr"] != nil
    end
  end

  # ─── handle_command ───────────────────────────────────────────────────────

  describe "handle_command — inbox.item.start" do
    test "first item → InboxItemStarted event" do
      state = %InboxThread.State{messages: %{}, correlation_index: %{}}

      command = %{
        type: "inbox.item.start",
        payload: %{
          run_id: "run-1",
          correlation_id: "corr-new",
          source: "bridge",
          payload: %{"body" => "hello"}
        }
      }

      assert {:ok, spec} = InboxThread.handle_command(state, command)
      assert spec.event_type == "InboxItemStarted"
      assert spec.payload.correlation_id == "corr-new"
      assert spec.payload.source == "bridge"
    end

    test "missing required field → error" do
      state = %InboxThread.State{messages: %{}, correlation_index: %{}}

      command = %{
        type: "inbox.item.start",
        payload: %{
          run_id: "run-1"
          # missing correlation_id and source
        }
      }

      assert {:error, _} = InboxThread.handle_command(state, command)
    end
  end
end

defmodule ForemanServer.EventCodecMismatchTest do
  use ExUnit.Case, async: true

  alias ForemanServer.{EventCodec, Events.InboxItemStarted, Events.InboxItemDeduped}

  describe "EventCodec.decode!/2 mismatched-struct rejection" do
    test "InboxItemDeduped struct under InboxItemStarted event_type raises" do
      wrong_struct = %InboxItemDeduped{
        correlation_id: "corr-wrong",
        run_id: "run-wrong-1",
        source: "test",
        timestamp: ~U[2026-07-29T12:00:00Z]
      }

      assert_raise RuntimeError, ~r/InboxItemStarted.*InboxItemDeduped/, fn ->
        EventCodec.decode!("InboxItemStarted", wrong_struct)
      end
    end
    test "InboxItemStarted struct under InboxItemDeduped event_type raises" do
      wrong_struct = %InboxItemStarted{
        correlation_id: "corr-wrong",
        run_id: "run-wrong-2",
        source: "test",
        timestamp: ~U[2026-07-29T12:00:00Z],
        payload: %{}
      }

      assert_raise RuntimeError, ~r/InboxItemDeduped.*InboxItemStarted/, fn ->
        EventCodec.decode!("InboxItemDeduped", wrong_struct)
      end
    end
    test "matching typed struct passes through unchanged" do
      matching = %InboxItemStarted{
        correlation_id: "corr-ok",
        run_id: "run-ok",
        source: "test",
        timestamp: ~U[2026-07-29T12:00:00Z],
        payload: %{}
      }

      result = EventCodec.decode!("InboxItemStarted", matching)
      assert result == matching
    end
    test "plain map is reconstructed via from_payload" do
      plain = %{
        "correlation_id" => "corr-map",
        "run_id" => "run-map",
        "source" => "bridge",
        "timestamp" => "2026-07-29T12:00:00Z"
      }

      result = EventCodec.decode!("InboxItemDeduped", plain)
      assert %InboxItemDeduped{correlation_id: "corr-map"} = result
    end
  end
end

defmodule ForemanServer.SharedInboxTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Inbox.SharedInbox

  # Minimal behaviour implementations
  defmodule ValidImpl do
    @behaviour ForemanServer.Inbox.InboxItemCorrelationId
    @impl true
    def correlation_id(payload), do: Map.get(payload, "correlation_id")
  end

  defmodule EmptyImpl do
    @behaviour ForemanServer.Inbox.InboxItemCorrelationId
    @impl true
    def correlation_id(_payload), do: ""
  end

  defmodule MissingCallbackImpl do
    # Does NOT implement InboxItemCorrelationId — no correlation_id/1 function
    def unrelated(_payload), do: :ignored
  end

  describe "SharedInbox.ingest/2 error paths" do
    test "invalid (empty) correlation_id → error" do
      payload = %{"correlation_id" => "", "source" => "bridge", "run_id" => "run-1"}

      assert {:error, {:invalid_correlation_id, ValidImpl}} =
               SharedInbox.ingest(ValidImpl, payload)
    end

    test "nil correlation_id → error" do
      payload = %{"correlation_id" => nil, "source" => "bridge", "run_id" => "run-1"}

      assert {:error, {:invalid_correlation_id, ValidImpl}} =
               SharedInbox.ingest(ValidImpl, payload)
    end

    test "module not implementing InboxItemCorrelationId → error" do
      payload = %{"source" => "bridge", "run_id" => "run-1"}

      assert {:error, {:not_inbox_correlation_id_impl, MissingCallbackImpl}} =
               SharedInbox.ingest(MissingCallbackImpl, payload)
    end
  end
end
