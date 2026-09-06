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

  test "catch-up selects only enqueued notifications with no prior attempt" do
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

    assert [%Notification{notification_id: "n-1"}] = Dispatcher.pending_notifications(events)
  end

  test "catch-up treats success and failure as prior attempts" do
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
          correlation_id: "corr-failed"
        }
      }
    ]

    assert [] = Dispatcher.pending_notifications(events)
  end
end
