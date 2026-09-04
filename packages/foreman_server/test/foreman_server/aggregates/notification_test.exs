defmodule ForemanServer.Aggregates.NotificationTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.Notification

  @payload %{
    provider: :telegram,
    recipient: "chat-1",
    event_class: :failure,
    severity: :critical,
    subject: "Run failed",
    body: "phase failed",
    correlation_id: "run-1:failure",
    run_id: "run-1",
    now_ms: 1_000,
    dedupe_window_ms: 300_000
  }

  test "enqueues a new notification" do
    assert {:ok, event} =
             Notification.handle_command(Notification.initial_state(), %{
               type: "notification.enqueue",
               payload: @payload
             })

    assert event.stream_id == "notification:run-1:failure"
    assert event.event_type == "NotificationEnqueued"
    assert event.payload.notification_id == "telegram:run-1:failure"
  end

  test "dedupes repeated correlation ids inside window" do
    state =
      Notification.apply_event(Notification.initial_state(), %{
        event_type: "NotificationEnqueued",
        payload: Map.put(@payload, :notification_id, "n-1")
      })

    assert {:ok, event} =
             Notification.handle_command(state, %{
               type: "notification.enqueue",
               payload: %{@payload | now_ms: 2_000}
             })

    assert event.event_type == "NotificationSuppressed"
    assert event.payload.reason == "duplicate"
  end

  test "records delivery result transitions" do
    state = %Notification.State{
      Notification.initial_state()
      | exists?: true,
        notification_id: "n-1",
        correlation_id: "corr-1",
        provider: "telegram"
    }

    assert {:ok, attempted} =
             Notification.handle_command(state, %{
               type: "notification.delivery_attempt",
               payload: %{attempt_id: "a-1"}
             })

    assert attempted.event_type == "NotificationDeliveryAttempted"

    assert {:ok, failed} =
             Notification.handle_command(state, %{
               type: "notification.delivery_failure",
               payload: %{attempt_id: "a-1", reason: "timeout", retryable?: true}
             })

    assert failed.event_type == "NotificationDeliveryFailed"
    assert failed.payload.reason == "timeout"
  end
end
