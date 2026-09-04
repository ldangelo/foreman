defmodule ForemanServer.Agents.SignalToCommandAdapterUnitTest do
  @moduledoc """
  Unit tests for `SignalToCommandAdapter.normalize/1` in isolation.

  TRD-2026-4212be7e / JCR-T008 / TRD-010.
  Verifies: CloudEvent envelope parsing, trigger_id priority chain,
  ExternalTriggerCommand envelope shape, and error handling.

  NOTE: The implementation validates `specversion` and `trigger_id` fields
  (via `require_specversion` / `require_trigger_id`). The `id` (cloud_event_id)
  field is NOT validated — it may be absent, in which case command_id is nil.
  """
  use ExUnit.Case, async: true

  alias ForemanServer.Agents.SignalToCommandAdapter

  # -------------------------------------------------------------------------
  # CloudEvent envelope parsing
  # -------------------------------------------------------------------------

  describe "normalize/1 parses valid CloudEvent envelopes" do
    test "parses minimal valid CloudEvent with required fields" do
      event = %{
        "specversion" => "1.0",
        "id" => "evt-001",
        "source" => "test/agent",
        "type" => "foreman/commands",
        "trigger_id" => "evt-001",
        "data" => %{"command" => "task.create", "args" => %{"title" => "Hello"}}
      }

      assert {:ok, envelope} = SignalToCommandAdapter.normalize(event)
      assert envelope.command_id == "evt-001"
      assert envelope.type == "external.trigger"
      assert envelope.aggregate_id == "external:evt-001"
      assert envelope.payload.command == "task.create"
      assert envelope.payload.args == %{"title" => "Hello"}
    end

    test "uses trigger_id from CloudEvents extension field" do
      event = %{
        "specversion" => "1.0",
        "id" => "evt-002",
        "source" => "test/agent",
        "trigger_id" => "trigger-abc",
        "data" => %{"command" => "task.create"}
      }

      assert {:ok, envelope} = SignalToCommandAdapter.normalize(event)
      assert envelope.aggregate_id == "external:trigger-abc"
      assert envelope.payload.trigger_id == "trigger-abc"
    end

    test "uses dedupe_key as trigger_id when trigger_id absent" do
      event = %{
        "specversion" => "1.0",
        "id" => "evt-003",
        "source" => "test/agent",
        "dedupe_key" => "dedupe-xyz",
        "data" => %{"command" => "task.create"}
      }

      assert {:ok, envelope} = SignalToCommandAdapter.normalize(event)
      assert envelope.aggregate_id == "external:dedupe-xyz"
    end

    test "uses command_id as trigger_id fallback" do
      event = %{
        "specversion" => "1.0",
        "id" => "evt-004",
        "source" => "test/agent",
        "command_id" => "cmd-456",
        "data" => %{"command" => "task.create"}
      }

      assert {:ok, envelope} = SignalToCommandAdapter.normalize(event)
      assert envelope.aggregate_id == "external:cmd-456"
    end

    test "falls back to data.trigger_id when top-level fields absent" do
      event = %{
        "specversion" => "1.0",
        "id" => "evt-005",
        "source" => "test/agent",
        "data" => %{"trigger_id" => "data-trigger", "command" => "task.create"}
      }

      assert {:ok, envelope} = SignalToCommandAdapter.normalize(event)
      assert envelope.aggregate_id == "external:data-trigger"
    end

    test "falls back to data.id when no trigger fields present at top level" do
      event = %{
        "specversion" => "1.0",
        "id" => "evt-006",
        "source" => "test/agent",
        "data" => %{"id" => "data-id-789", "command" => "task.create"}
      }

      assert {:ok, envelope} = SignalToCommandAdapter.normalize(event)
      assert envelope.aggregate_id == "external:data-id-789"
    end

    test "handles atom-keyed map (Jido.Signal struct) with trigger_id" do
      # Jido.Signal uses atom keys internally
      event = %{
        :specversion => "1.0",
        :id => "evt-007",
        :source => "test/agent",
        :trigger_id => "atom-trigger",
        :data => %{:command => "task.create", :args => %{}}
      }

      assert {:ok, envelope} = SignalToCommandAdapter.normalize(event)
      assert envelope.command_id == "evt-007"
      assert envelope.payload.trigger_id == "atom-trigger"
    end

    test "normalizes nil data to empty args map" do
      event = %{
        "specversion" => "1.0",
        "id" => "evt-008",
        "source" => "test/agent",
        "trigger_id" => "trigger-008",
        "data" => nil
      }

      assert {:ok, envelope} = SignalToCommandAdapter.normalize(event)
      assert envelope.payload.args == %{}
    end
  end

  # -------------------------------------------------------------------------
  # Error handling for malformed CloudEvents
  # -------------------------------------------------------------------------

  describe "normalize/1 rejects malformed CloudEvents" do
    test "rejects missing specversion" do
      event = %{
        "id" => "evt-bad-001",
        "source" => "test/agent",
        "trigger_id" => "t-bad-001",
        "data" => %{"command" => "task.create"}
      }

      assert {:error, {:invalid_cloud_event, :missing_specversion}} =
               SignalToCommandAdapter.normalize(event)
    end

    test "rejects invalid specversion" do
      event = %{
        "specversion" => "0.3",
        "id" => "evt-bad-002",
        "source" => "test/agent",
        "trigger_id" => "t-bad-002",
        "data" => %{"command" => "task.create"}
      }

      assert {:error, {:invalid_cloud_event, :missing_specversion}} =
               SignalToCommandAdapter.normalize(event)
    end

    test "rejects missing trigger_id and all fallbacks" do
      event = %{
        "specversion" => "1.0",
        "id" => "evt-bad-003",
        "source" => "test/agent",
        "data" => %{}
      }

      assert {:error, {:invalid_cloud_event, :missing_trigger_id}} =
               SignalToCommandAdapter.normalize(event)
    end

    test "rejects non-map input" do
      assert {:error, {:invalid_cloud_event, :not_a_map}} =
               SignalToCommandAdapter.normalize("not a map")

      assert {:error, {:invalid_cloud_event, :not_a_map}} =
               SignalToCommandAdapter.normalize(nil)

      assert {:error, {:invalid_cloud_event, :not_a_map}} =
               SignalToCommandAdapter.normalize(a: 1)
    end
  end

  # -------------------------------------------------------------------------
  # id / cloud_event_id is NOT validated (implementation contract)
  # -------------------------------------------------------------------------

  describe "normalize/1 does NOT validate the id (cloud_event_id) field" do
    # The implementation does not call require_id; id may be absent.
    # This is the existing contract — recorded as a behavioural test.

    test "succeeds when id field is absent but trigger_id is present" do
      event = %{
        "specversion" => "1.0",
        "source" => "test/agent",
        "trigger_id" => "t-no-id",
        "data" => %{"command" => "task.create"}
      }

      assert {:ok, envelope} = SignalToCommandAdapter.normalize(event)
      assert envelope.command_id == nil
      assert envelope.aggregate_id == "external:t-no-id"
    end
  end

  # -------------------------------------------------------------------------
  # ExternalTriggerCommand envelope contract
  # -------------------------------------------------------------------------

  describe "normalize/1 returns ExternalTriggerCommand envelope shape" do
    test "envelope has required top-level fields" do
      event = %{
        "specversion" => "1.0",
        "id" => "evt-shape",
        "source" => "test/agent",
        "trigger_id" => "trigger-shape",
        "data" => %{"command" => "task.create", "args" => %{"x" => 1}}
      }

      assert {:ok, envelope} = SignalToCommandAdapter.normalize(event)
      assert Map.has_key?(envelope, :command_id)
      assert Map.has_key?(envelope, :type)
      assert Map.has_key?(envelope, :aggregate_id)
      assert Map.has_key?(envelope, :payload)
    end

    test "envelope payload has required fields" do
      event = %{
        "specversion" => "1.0",
        "id" => "evt-payload",
        "source" => "test/agent",
        "trigger_id" => "trigger-payload",
        "data" => %{"command" => "task.create", "args" => %{"x" => 1}}
      }

      assert {:ok, envelope} = SignalToCommandAdapter.normalize(event)
      payload = envelope.payload
      assert Map.has_key?(payload, :trigger_id)
      assert Map.has_key?(payload, :cloud_event_id)
      assert Map.has_key?(payload, :source)
      assert Map.has_key?(payload, :command)
      assert Map.has_key?(payload, :args)
    end

    test "envelope type is always external.trigger" do
      event = %{
        "specversion" => "1.0",
        "id" => "evt-type",
        "source" => "test/agent",
        "trigger_id" => "trigger-type",
        "data" => %{"command" => "task.create"}
      }

      assert {:ok, envelope} = SignalToCommandAdapter.normalize(event)
      assert envelope.type == "external.trigger"
    end

    test "aggregate_id format is external:{trigger_id}" do
      event = %{
        "specversion" => "1.0",
        "id" => "evt-agg",
        "source" => "test/agent",
        "trigger_id" => "my-trigger",
        "data" => %{"command" => "task.create"}
      }

      assert {:ok, envelope} = SignalToCommandAdapter.normalize(event)
      assert envelope.aggregate_id == "external:my-trigger"
    end
  end
end
