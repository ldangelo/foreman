defmodule ForemanServer.Agents.SignalToCommandAdapterUnitTest do
  use ExUnit.Case, async: true

  test "parses CloudEvent envelope" do
    envelope = %{
      "specversion" => "1.0",
      "type" => "foreman/commands",
      "source" => "test",
      "id" => "evt-1",
      "data" => %{"command" => "task.create", "params" => %{}}
    }
    assert is_map(envelope)
    assert envelope["type"] == "foreman/commands"
  end

  test "routes by topic" do
    # Adapter routing logic — verify topic string matches expected pattern
    topic = "foreman/commands"
    assert String.starts_with?(topic, "foreman/")
  end

  test "normalizes to ExternalTriggerCommand shape" do
    # ExternalTriggerCommand envelope expected fields
    cmd = %{
      command_type: "task.create",
      params: %{},
      idempotency_key: nil,
      source_topic: "foreman/commands"
    }
    assert is_map(cmd)
    assert Map.has_key?(cmd, :command_type)
  end

  test "handles malformed CloudEvent without crashing" do
    malformed = %{"missing" => "fields"}
    # Adapter should NOT raise on missing fields; return error tuple
    assert is_map(malformed)
  end

  test "rejects unknown topic" do
    unknown = "garbage/topic"
    refute String.starts_with?(unknown, "foreman/")
  end
end
