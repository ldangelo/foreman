defmodule ForemanServer.Messaging.DispatcherTest do
  # async: false — the destination/1 tests below mutate the shared
  # :foreman_server, :messaging Application env (same reason
  # ConfigResolverTest is async: false).
  use ExUnit.Case, async: false

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

  describe "destination/1" do
    setup do
      original = Application.get_env(:foreman_server, :messaging)

      on_exit(fn ->
        if is_nil(original),
          do: Application.delete_env(:foreman_server, :messaging),
          else: Application.put_env(:foreman_server, :messaging, original)
      end)

      :ok
    end

    test "does not reuse ConfigResolver's malformed-destination code for a provider mismatch" do
      # Config is valid for telegram, but this notification is for slack: no
      # destination exists for it, which is a different cause than a
      # malformed one (CodeRabbit review; AGENTS.md 5.3).
      Application.put_env(:foreman_server, :messaging,
        enabled: true,
        provider: :telegram,
        telegram: [token: "t-token", chat_id: "t-chat"]
      )

      {:ok, notification} = Notification.normalize(%{@notification | provider: :slack})

      assert {:error, {:provider_not_configured, :slack}} = Dispatcher.destination(notification)
    end

    test "resolves a destination for the matching provider, keyed by the notification's recipient" do
      Application.put_env(:foreman_server, :messaging,
        enabled: true,
        provider: :telegram,
        telegram: [token: "t-token", chat_id: "config-chat"]
      )

      {:ok, notification} = Notification.normalize(@notification)

      assert {:ok, %{token: "t-token", chat_id: "chat-1"}} = Dispatcher.destination(notification)
    end
  end
end
