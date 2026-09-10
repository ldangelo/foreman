defmodule ForemanServer.MessagingTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Messaging

  @attrs %{
    provider: :telegram,
    recipient: "chat-1",
    event_class: :failure,
    severity: :critical,
    subject: "Run failed",
    body: "phase failed",
    run_id: "run-1"
  }

  test "notify/2 returns the notification id on a fresh enqueue" do
    correlation_id = "notify-fresh-#{System.unique_integer([:positive])}"
    attrs = Map.put(@attrs, :correlation_id, correlation_id)

    assert {:ok, "telegram:" <> ^correlation_id} = Messaging.notify(attrs)
  end

  test "notify/2 returns the notification id on a duplicate (suppressed) enqueue" do
    correlation_id = "notify-dup-#{System.unique_integer([:positive])}"
    attrs = Map.put(@attrs, :correlation_id, correlation_id)

    assert {:ok, notification_id} = Messaging.notify(attrs)
    assert {:ok, ^notification_id} = Messaging.notify(attrs)
  end
end
