defmodule ForemanServer.ProjectionStoreQueueStatusTest do
  use ExUnit.Case, async: false

  alias EventStore.EventData
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.ProjectionStore

  @run_slots_stream "run_slots:global"

  setup do
    cleanup_run_slots_stream()
    reset_projection_store()

    on_exit(fn ->
      cleanup_run_slots_stream()
      reset_projection_store()
    end)

    :ok
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
    _ = Store.delete_stream(@run_slots_stream, :any_version, :hard)
    :ok
  end

  defp reset_projection_store do
    :sys.replace_state(ForemanServer.ProjectionStore, fn state ->
      %{
        projects: %{},
        runs: %{},
        tasks: %{},
        phases: %{},
        pr_associations: %{},
        scheduler_intents: %{},
        worktrees: %{},
        worktree_create_orphans: %{},
        subscribers: Map.get(state, :subscribers, %{}),
        run_slots: %{capacity: 0, holders: %{}, waiters: []},
        works: %{},
        project_active_runs: %{}
      }
    end)
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
