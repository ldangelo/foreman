defmodule ForemanServer.Messaging.NotificationTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Messaging.Notification

  @valid %{
    provider: :telegram,
    recipient: "chat-1",
    event_class: :failure,
    severity: :critical,
    subject: "Run failed",
    body: "phase failed",
    correlation_id: "run-1:failure",
    run_id: "run-1",
    metadata: %{run_id: "run-1", prompt: "secret prompt", artifact: "raw artifact"}
  }

  test "normalizes valid notification maps into typed structs" do
    assert {:ok, %Notification{} = notification} = Notification.normalize(@valid)
    assert notification.notification_id == "telegram:run-1:failure"
    assert notification.provider == :telegram
    assert notification.metadata == %{run_id: "run-1"}
  end

  test "rejects unknown keys instead of silently dropping known data" do
    assert {:error, {:unknown_keys, [:raw_prompt]}} =
             Notification.normalize(Map.put(@valid, :raw_prompt, "leak"))
  end

  test "returns typed unsupported-provider errors" do
    assert {:error, {:missing_or_invalid, :provider, "irc"}} =
             Notification.normalize(%{@valid | provider: "irc"})
  end

  test "rejects metadata maps with non-atom, non-binary keys instead of crashing" do
    assert {:error, {:missing_or_invalid, :metadata, _}} =
             Notification.normalize(%{@valid | metadata: %{1 => "x"}})
  end
end
