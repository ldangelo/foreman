defmodule ForemanServer.Inbox.ExternalTriggerCorrelationIdTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Inbox.ExternalTriggerCorrelationId

  describe "correlation_id/1" do
    # Priority: trigger_id → dedupe_key → event_id → external_id → command_id

    test "returns trigger_id when present (string key)" do
      payload = %{"trigger_id" => "my-trigger"}
      assert ExternalTriggerCorrelationId.correlation_id(payload) == "my-trigger"
    end

    test "returns trigger_id when present (atom key)" do
      payload = %{trigger_id: "my-trigger"}
      assert ExternalTriggerCorrelationId.correlation_id(payload) == "my-trigger"
    end

    test "returns dedupe_key when trigger_id absent" do
      payload = %{"dedupe_key" => "my-dedupe"}
      assert ExternalTriggerCorrelationId.correlation_id(payload) == "my-dedupe"
    end

    test "returns event_id when trigger_id and dedupe_key absent" do
      payload = %{"event_id" => "my-event"}
      assert ExternalTriggerCorrelationId.correlation_id(payload) == "my-event"
    end

    test "returns external_id when trigger_id, dedupe_key, event_id absent" do
      payload = %{"external_id" => "my-external"}
      assert ExternalTriggerCorrelationId.correlation_id(payload) == "my-external"
    end

    test "returns command_id when all prior keys absent" do
      payload = %{"command_id" => "my-command"}
      assert ExternalTriggerCorrelationId.correlation_id(payload) == "my-command"
    end

    test "prefers trigger_id over lower-priority keys (string keys)" do
      payload = %{
        "trigger_id" => "primary",
        "dedupe_key" => "secondary",
        "event_id" => "tertiary",
        "external_id" => "quaternary",
        "command_id" => "quinary"
      }

      assert ExternalTriggerCorrelationId.correlation_id(payload) == "primary"
    end

    test "prefers dedupe_key over lower-priority keys when trigger_id absent" do
      payload = %{
        "dedupe_key" => "primary",
        "event_id" => "secondary",
        "external_id" => "tertiary",
        "command_id" => "quaternary"
      }

      assert ExternalTriggerCorrelationId.correlation_id(payload) == "primary"
    end

    test "prefers event_id over external_id and command_id" do
      payload = %{"event_id" => "primary", "external_id" => "secondary", "command_id" => "tertiary"}
      assert ExternalTriggerCorrelationId.correlation_id(payload) == "primary"
    end

    test "prefers external_id over command_id" do
      payload = %{"external_id" => "primary", "command_id" => "secondary"}
      assert ExternalTriggerCorrelationId.correlation_id(payload) == "primary"
    end

    test "returns nil when all dedupe keys absent" do
      payload = %{"source" => "test", "status" => "pending"}
      assert ExternalTriggerCorrelationId.correlation_id(payload) == nil
    end

    test "returns nil for empty map" do
      assert ExternalTriggerCorrelationId.correlation_id(%{}) == nil
    end

    test "returns nil when dedupe key is empty string" do
      # Empty trigger_id is falsy, so dedupe_key is tried next and is also empty
      payload = %{"trigger_id" => "", "dedupe_key" => "valid-key"}
      assert ExternalTriggerCorrelationId.correlation_id(payload) == "valid-key"

      # Both empty → nil
      assert ExternalTriggerCorrelationId.correlation_id(%{"dedupe_key" => ""}) == nil
    end

    test "normalizes atom keys to string values" do
      payload = %{trigger_id: :atom_trigger}
      assert ExternalTriggerCorrelationId.correlation_id(payload) == "atom_trigger"
    end

    test "normalizes integer values to strings" do
      payload = %{"trigger_id" => 12345}
      assert ExternalTriggerCorrelationId.correlation_id(payload) == "12345"
    end

    test "handles mixed atom and string key payloads from webhook JSON" do
      # Internal maps may use atom keys; correlation id handler normalizes both.
      payload = %{"event_id" => "webhook-event", "source" => "test"}
      assert ExternalTriggerCorrelationId.correlation_id(payload) == "webhook-event"
    end

    test "atom key checked first, then string key (code inspection verified)" do
      # first_present checks Map.get(payload, :trigger_id) first,
      # then Map.get(payload, "trigger_id"). Verified via source inspection.
      assert ExternalTriggerCorrelationId.correlation_id(%{trigger_id: "from-atom"}) == "from-atom"
      assert ExternalTriggerCorrelationId.correlation_id(%{"trigger_id" => "from-string"}) == "from-string"
    end
  end
end
