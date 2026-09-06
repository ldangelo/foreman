defmodule ForemanServer.Messaging.DispatcherTest do
  use ExUnit.Case, async: true

  alias EventStore.EventData
  alias ForemanServer.Messaging.{Dispatcher, Notification}

  @notification %{
    notification_id: "n-1",
    provider: :telegram,
    recipient: "chat-1",
    event_class: :failure,
    severity: :critical,
    subject: "Run failed",
    body: "phase failed",
    correlation_id: "corr-1",
    run_id: "run-1",
    metadata: %{run_id: "run-1"}
  }

  test "catch-up retries an enqueued notification with an in-flight attempt and no recorded outcome" do
    # An attempt alone is not terminal: the dispatching process may have
    # crashed before recording success or failure, so catch-up must still
    # retry it rather than treating "attempted" as done (CodeRabbit review).
    attempted = %{
      @notification
      | notification_id: "n-attempted",
        correlation_id: "corr-attempted"
    }

    events = [
      %EventData{event_type: "NotificationEnqueued", data: @notification},
      %EventData{event_type: "NotificationEnqueued", data: attempted},
      %EventData{
        event_type: "NotificationDeliveryAttempted",
        data: %{
          notification_id: "n-attempted",
          attempt_id: "a-1",
          provider: "telegram",
          correlation_id: "corr-attempted"
        }
      }
    ]

    ids = events |> Dispatcher.pending_notifications() |> Enum.map(& &1.notification_id)
    assert Enum.sort(ids) == ["n-1", "n-attempted"]
  end

  test "catch-up treats success and non-retryable failure as terminal" do
    succeeded = %{@notification | notification_id: "n-ok", correlation_id: "corr-ok"}
    failed = %{@notification | notification_id: "n-failed", correlation_id: "corr-failed"}

    events = [
      %EventData{event_type: "NotificationEnqueued", data: succeeded},
      %EventData{event_type: "NotificationEnqueued", data: failed},
      %EventData{
        event_type: "NotificationDeliverySucceeded",
        data: %{
          notification_id: "n-ok",
          attempt_id: "a-1",
          provider: "telegram",
          correlation_id: "corr-ok"
        }
      },
      %EventData{
        event_type: "NotificationDeliveryFailed",
        data: %{
          notification_id: "n-failed",
          attempt_id: "a-1",
          provider: "telegram",
          correlation_id: "corr-failed",
          retryable?: false
        }
      }
    ]

    assert [] = Dispatcher.pending_notifications(events)
  end

  test "catch-up retries a notification whose only failure was retryable" do
    retried = %{@notification | notification_id: "n-retry", correlation_id: "corr-retry"}

    events = [
      %EventData{event_type: "NotificationEnqueued", data: retried},
      %EventData{
        event_type: "NotificationDeliveryFailed",
        data: %{
          notification_id: "n-retry",
          attempt_id: "a-1",
          provider: "telegram",
          correlation_id: "corr-retry",
          retryable?: true
        }
      }
    ]

    assert [%Notification{notification_id: "n-retry"}] = Dispatcher.pending_notifications(events)
  end

  test "malformed NotificationEnqueued payload is excluded from the pending set, not silently kept" do
    events = [
      %EventData{event_type: "NotificationEnqueued", data: %{notification_id: "n-1"}}
    ]

    assert [] = Dispatcher.pending_notifications(events)
  end
end
