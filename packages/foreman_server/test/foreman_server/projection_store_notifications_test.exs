defmodule ForemanServer.ProjectionStoreNotificationsTest do
  use ExUnit.Case, async: false

  alias EventStore.EventData
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.UniqueIds

  test "projects notification lifecycle into run detail" do
    run_id = UniqueIds.unique_run_id("n1")

    run_started = %EventData{
      event_type: "RunStarted",
      data: %{
        run_id: run_id,
        project_id: "p-1",
        task_id: "t-1",
        workflow_name: "wf",
        workflow_digest: "digest",
        workflow_snapshot: %{name: "wf"},
        sequence: 1
      }
    }

    enqueued = %EventData{
      event_type: "NotificationEnqueued",
      data: %{
        notification_id: "n-1",
        provider: "telegram",
        recipient: "chat-1",
        event_class: "failure",
        severity: "critical",
        subject: "Run failed",
        body: "phase failed",
        correlation_id: "corr-1",
        run_id: run_id,
        metadata: %{run_id: run_id}
      }
    }

    failed = %EventData{
      event_type: "NotificationDeliveryFailed",
      data: %{
        notification_id: "n-1",
        attempt_id: "a-1",
        provider: "telegram",
        correlation_id: "corr-1",
        run_id: run_id,
        reason: "timeout",
        retryable?: true
      }
    }

    assert :ok = ProjectionStore.apply_events([run_started, enqueued, failed])
    run = ProjectionStore.run(run_id)

    assert [
             %{
               notification_id: "n-1",
               status: "failed",
               reason: "timeout",
               retryable?: true,
               metadata: %{run_id: ^run_id}
             }
           ] = run.notifications
  end
end
