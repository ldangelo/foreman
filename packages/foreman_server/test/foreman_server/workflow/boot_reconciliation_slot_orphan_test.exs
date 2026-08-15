defmodule ForemanServer.Workflow.BootReconciliationSlotOrphanTest do
  use ExUnit.Case, async: false

  alias EventStore.RecordedEvent
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Workflow.BootReconciliation

  @run_slots_stream "run_slots:global"

  setup do
    cleanup_run_slots_stream()
    cleanup_boot_reconciliation_runs()

    on_exit(fn ->
      cleanup_run_slots_stream()
      cleanup_boot_reconciliation_runs()
    end)

    :ok
  end

  describe "scan_run_slot_orphans/0" do
    test "holder whose run is absent is released and slot given to next live waiter" do
      holder_run_id = unique_id("absent-holder")
      waiter_run_id = unique_id("live-waiter")

      seed_live_run!(waiter_run_id)
      append_run_slot_holder!(holder_run_id, 0, 1)
      append_run_slot_waiter!(waiter_run_id, 1, 1)

      assert :ok = BootReconciliation.scan_run_slot_orphans()

      assert_eventually(fn ->
        with {:ok, events} <- Store.read_stream_forward(@run_slots_stream, 0, 20),
             %RecordedEvent{
               event_type: "RunSlotTransferred",
               data: %{released_run_id: ^holder_run_id, acquired_run_id: ^waiter_run_id}
             } <- List.last(events) do
          :ok
        else
          other -> {:still_waiting, other}
        end
      end)
    end

    test "holder whose run is terminal is released" do
      holder_run_id = unique_id("terminal-holder")

      seed_terminal_run!(holder_run_id)
      append_run_slot_holder!(holder_run_id, 0, 1)

      assert :ok = BootReconciliation.scan_run_slot_orphans()

      assert_eventually(fn ->
        with {:ok, events} <- Store.read_stream_forward(@run_slots_stream, 0, 20),
             %RecordedEvent{event_type: "RunSlotReleased", data: %{run_id: ^holder_run_id}} <-
               List.last(events) do
          :ok
        else
          other -> {:still_waiting, other}
        end
      end)
    end

    test "waiter whose work was cancelled is removed and skipped" do
      holder_run_id = unique_id("live-holder")
      cancelled_waiter_run_id = unique_id("cancelled-waiter")
      live_waiter_run_id = unique_id("live-waiter")

      seed_live_run!(holder_run_id)
      seed_cancelled_run!(cancelled_waiter_run_id)
      seed_live_run!(live_waiter_run_id)

      append_run_slot_holder!(holder_run_id, 0, 1)
      append_run_slot_waiter!(cancelled_waiter_run_id, 1, 1)
      append_run_slot_waiter!(live_waiter_run_id, 2, 2)

      assert :ok = BootReconciliation.scan_run_slot_orphans()

      assert_eventually(fn ->
        with {:ok, events} <- Store.read_stream_forward(@run_slots_stream, 0, 30),
             true <-
               Enum.any?(events, fn
                 %RecordedEvent{
                   event_type: "RunSlotWaiterRemoved",
                   data: %{run_id: ^cancelled_waiter_run_id}
                 } ->
                   true

                 _ ->
                   false
               end) do
          :ok
        else
          other -> {:still_waiting, other}
        end
      end)

      assert ProjectionStore.queue_status().waiting == [live_waiter_run_id]
    end

    test "waiter list order is preserved after reconciliation" do
      holder_run_id = unique_id("live-holder")
      removed_waiter_run_id = unique_id("removed-waiter")
      waiter_two_run_id = unique_id("waiter-two")
      waiter_three_run_id = unique_id("waiter-three")

      seed_live_run!(holder_run_id)
      seed_terminal_run!(removed_waiter_run_id)
      seed_live_run!(waiter_two_run_id)
      seed_live_run!(waiter_three_run_id)

      append_run_slot_holder!(holder_run_id, 0, 1)
      append_run_slot_waiter!(removed_waiter_run_id, 1, 1)
      append_run_slot_waiter!(waiter_two_run_id, 2, 2)
      append_run_slot_waiter!(waiter_three_run_id, 3, 3)

      assert :ok = BootReconciliation.scan_run_slot_orphans()

      assert_eventually(fn ->
        case ProjectionStore.queue_status() do
          %{waiting: [^waiter_two_run_id, ^waiter_three_run_id]} -> :ok
          other -> {:still_waiting, other}
        end
      end)
    end
  end

  defp unique_id(prefix) do
    "#{prefix}-slot-orphan-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
  end

  defp cleanup_run_slots_stream do
    _ = Store.delete_stream(@run_slots_stream, :any_version, :hard)
    :ok
  end

  defp cleanup_boot_reconciliation_runs do
    :sys.replace_state(ProjectionStore, fn state ->
      %{
        state
        | runs:
            Map.reject(state.runs, fn {run_id, _run} ->
              String.contains?(run_id, "-slot-orphan-")
            end),
          run_slots: %{capacity: 0, holders: %{}, waiters: []}
      }
    end)
  end

  defp append_run_slot_holder!(run_id, version, capacity) do
    acquired_at_ms = System.system_time(:millisecond)

    :ok =
      Store.append_to_stream(@run_slots_stream, version, [
        %EventStore.EventData{
          event_type: "RunSlotAcquired",
          data: %{run_id: run_id, capacity: capacity, acquired_at_ms: acquired_at_ms},
          metadata: %{}
        }
      ])

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "RunSlotAcquired",
          payload: %{run_id: run_id, capacity: capacity, acquired_at_ms: acquired_at_ms}
        }
      ])
  end

  defp append_run_slot_waiter!(run_id, version, position) do
    enqueued_at_ms = System.system_time(:millisecond)

    :ok =
      Store.append_to_stream(@run_slots_stream, version, [
        %EventStore.EventData{
          event_type: "RunSlotQueued",
          data: %{run_id: run_id, position: position, enqueued_at_ms: enqueued_at_ms},
          metadata: %{}
        }
      ])

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "RunSlotQueued",
          payload: %{run_id: run_id, position: position, enqueued_at_ms: enqueued_at_ms}
        }
      ])
  end

  defp seed_live_run!(run_id) do
    append_and_apply("run:#{run_id}", 0, "RunStarted", %{
      run_id: run_id,
      task_id: unique_id("task"),
      project_id: unique_id("project"),
      workflow_snapshot: %{},
      sequence: 0
    })
  end

  defp seed_terminal_run!(run_id) do
    seed_live_run!(run_id)
    append_and_apply("run:#{run_id}", 1, "RunCompleted", %{run_id: run_id, sequence: 1})
  end

  defp seed_cancelled_run!(run_id) do
    seed_live_run!(run_id)

    append_and_apply("run:#{run_id}", 1, "RunCancelled", %{
      run_id: run_id,
      sequence: 1,
      status: "cancelled"
    })
  end

  defp append_and_apply(stream_uuid, expected_version, event_type, payload) do
    :ok =
      Store.append_to_stream(stream_uuid, expected_version, [
        %EventStore.EventData{event_type: event_type, data: payload, metadata: %{}}
      ])

    :ok = ProjectionStore.apply_events([%{event_type: event_type, payload: payload}])
  end

  defp assert_eventually(fun, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_until(fun, deadline)
  end

  defp poll_until(fun, deadline) do
    case fun.() do
      :ok ->
        :ok

      other ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("assert_eventually timed out; last value: #{inspect(other)}")
        else
          Process.sleep(20)
          poll_until(fun, deadline)
        end
    end
  end
end
