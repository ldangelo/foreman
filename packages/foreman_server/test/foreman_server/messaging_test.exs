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

  # `event_class: :failure` is enabled by ConfigResolver's own defaults; only
  # `enabled?` itself defaults to false, so tests exercising a real enqueue
  # (not a "disabled" suppression) must opt in explicitly, and enabling
  # requires a resolvable telegram destination.
  @opts [
    project_config: %{
      messaging: %{
        enabled: true,
        telegram: %{token: "test-token", chat_id: "test-chat"}
      }
    }
  ]

  test "notify/2 returns the notification id on a fresh enqueue" do
    correlation_id = "notify-fresh-#{System.unique_integer([:positive])}"
    attrs = Map.put(@attrs, :correlation_id, correlation_id)

    assert {:ok, "telegram:" <> ^correlation_id} = Messaging.notify(attrs, @opts)

    assert {:ok, [%{event_type: "NotificationEnqueued"}]} =
             ForemanServer.EventStore.read_stream_forward(
               "notification:#{correlation_id}",
               0,
               10
             )
  end

  test "notify/2 returns the notification id on a duplicate (suppressed) enqueue" do
    correlation_id = "notify-dup-#{System.unique_integer([:positive])}"
    attrs = Map.put(@attrs, :correlation_id, correlation_id)

    assert {:ok, notification_id} = Messaging.notify(attrs, @opts)
    assert {:ok, ^notification_id} = Messaging.notify(attrs, @opts)

    assert {:ok, events} =
             ForemanServer.EventStore.read_stream_forward(
               "notification:#{correlation_id}",
               0,
               10
             )

    assert Enum.map(events, & &1.event_type) == [
             "NotificationEnqueued",
             "NotificationSuppressed"
           ]
  end
end
