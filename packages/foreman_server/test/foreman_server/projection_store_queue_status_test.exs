defmodule ForemanServer.ProjectionStoreQueueStatusTest do
  use ExUnit.Case, async: false

  alias EventStore.EventData
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.{ProjectionStoreReset, RunSlotsReset}
  alias ForemanServer.Workflow.Dispatcher

  @run_slots_stream "run_slots:global"

  setup do
    # `run_slots:global` is a process-wide stream that the application's real
    # Dispatcher also writes (`run_slots.release`) whenever it handles a terminal
    # run event that an earlier test emitted. That handler can still be running,
    # or queued, when this test starts, and its append would land between the
    # stream cleanup below and this test's own expected-version-0 append. Freeze
    # the Dispatcher first: `:sys.suspend/1` returns only once it has finished
    # the message it was handling.
    :ok = ForemanServer.DispatcherQuiesce.suspend!()
    cleanup_run_slots_stream()
    reset_projection_store()

    on_exit(fn ->
      cleanup_run_slots_stream()
      reset_projection_store()
    end)

    :ok
  end

  describe "stream isolation" do
    test "a terminal run event emitted by this test does not reach run_slots:global while the Dispatcher is frozen" do
      RunSlotsReset.reset!()
      holder = unique_id("terminal-holder")

      assert {:ok, _} =
               ForemanServer.CommandGateway.dispatch_system(%{
                 type: "run_slots.acquire",
                 aggregate_id: @run_slots_stream,
                 command_id: "queue-status-isolation:#{holder}",
                 payload: %{
                   run_id: holder,
                   capacity: 1,
                   acquired_at_ms: System.system_time(:millisecond)
                 }
               })

      # The Dispatcher reads a recorded event's `data`; the projection reads its
      # `payload`. Carry both so this event looks like one the router recorded.
      terminal = %{
        run_id: holder,
        task_id: unique_id("task"),
        project_id: unique_id("project"),
        sequence: 1
      }

      :ok =
        ProjectionStore.apply_events([
          %{event_type: "RunCompleted", payload: terminal, data: terminal}
        ])

      # Barrier: answered after every message already in the Dispatcher's
      # mailbox. Were it not frozen, its slot release would be on the stream now.
      _ = :sys.get_state(Dispatcher)

      assert {:ok, recorded} = Store.read_stream_forward(@run_slots_stream)
      assert Enum.map(recorded, & &1.event_type) == ["RunSlotAcquired"]

      # Drain the queued terminal event before this test's cleanup so its
      # release cannot outlive the test and land in a later one.
      :ok = :sys.resume(Dispatcher)
      _ = :sys.get_state(Dispatcher)
    end
  end

  describe "queue_status/0" do
    test "reports capacity, running, and waiting across acquire/queue/transfer sequences" do
      run_1 = unique_id("holder")
      run_2 = unique_id("holder")
      run_3 = unique_id("waiter")
      run_4 = unique_id("waiter")

      append_and_apply(@run_slots_stream, 0, "RunSlotAcquired", %{
        run_id: run_1,
        capacity: 2,
        acquired_at_ms: 100
      })

      append_and_apply(@run_slots_stream, 1, "RunSlotAcquired", %{
        run_id: run_2,
        capacity: 2,
        acquired_at_ms: 101
      })

      append_and_apply(@run_slots_stream, 2, "RunSlotQueued", %{
        run_id: run_3,
        position: 1,
        enqueued_at_ms: 200
      })

      append_and_apply(@run_slots_stream, 3, "RunSlotQueued", %{
        run_id: run_4,
        position: 2,
        enqueued_at_ms: 201
      })

      assert ProjectionStore.queue_status() == %{
               capacity: 2,
               running: [run_1, run_2],
               waiting: [run_3, run_4]
             }

      append_and_apply(@run_slots_stream, 4, "RunSlotTransferred", %{
        released_run_id: run_1,
        acquired_run_id: run_3,
        capacity: 2,
        acquired_at_ms: 300
      })

      assert ProjectionStore.queue_status() == %{
               capacity: 2,
               running: [run_2, run_3],
               waiting: [run_4]
             }
    end
  end

  defp cleanup_run_slots_stream do
    case Store.delete_stream(@run_slots_stream, :any_version, :hard) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, :stream_not_found} -> :ok
    end
  end

  defp reset_projection_store do
    ProjectionStoreReset.reset!(keep_subscribers: true)
  end

  defp append_and_apply(stream_uuid, expected_version, event_type, payload) do
    :ok =
      Store.append_to_stream(stream_uuid, expected_version, [
        %EventData{event_type: event_type, data: payload, metadata: %{}}
      ])

    :ok = ProjectionStore.apply_events([%{event_type: event_type, payload: payload}])
  end

  defp unique_id(prefix) do
    "#{prefix}-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
  end
end
