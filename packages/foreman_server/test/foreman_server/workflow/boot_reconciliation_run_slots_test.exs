defmodule ForemanServer.Workflow.BootReconciliationRunSlotsTest do
  use ExUnit.Case, async: false

  alias EventStore.EventData
  alias EventStore.RecordedEvent
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.{ProjectionStore, Telemetry}

  @run_slots_stream "run_slots:global"

  setup do
    cleanup_run_slots_stream()
    cleanup_boot_reconciliation_runs()

    on_exit(fn ->
      cleanup_run_slots_stream()
    end)

    :ok
  end

  setup do
    {handler_id, ref} =
      ForemanServer.TelemetryTest.Handler.attach_event_handlers(self(), Telemetry.all_events())

    on_exit(fn -> :telemetry.detach(handler_id) end)
    {:ok, telemetry_ref: ref}
  end

  describe "scan_run_slot_orphans/0" do
    test "no holders or waiters → no dispatches" do
      assert :ok = BootReconciliation.scan_run_slot_orphans()
    end

    test "holder with terminal run → run_slots.release dispatched", %{telemetry_ref: ref} do
      terminal_run_id = unique_id("orphan-holder-run")

      seed_terminal_run!(terminal_run_id)
      # Append holder directly to bypass aggregate actor state issues
      append_run_slot_holder!(terminal_run_id, 0)

      assert :ok = BootReconciliation.scan_run_slot_orphans()

      assert_eventually(fn ->
        case Store.read_stream_forward(@run_slots_stream, 0, 20) do
          {:ok, events} ->
            case List.last(events) do
              %RecordedEvent{
                event_type: "RunSlotReleased",
                data: %{run_id: ^terminal_run_id}
              } ->
                :ok

              other ->
                {:still_waiting, other}
            end

          other ->
            {:still_waiting, other}
        end
      end)

      assert_receive {[:foreman_server, :run_slots, :reconciled], ^ref,
                      %{holders_dropped: 1, waiters_dropped: 0}, %{phase: :boot}}
    end

    test "holder with live run → no release dispatched" do
      live_run_id = unique_id("live-holder-run")

      seed_live_run!(live_run_id)
      append_run_slot_holder!(live_run_id, 0)

      assert :ok = BootReconciliation.scan_run_slot_orphans()

      Process.sleep(100)

      assert {:ok, events} = Store.read_stream_forward(@run_slots_stream, 0, 20)
      released_events = Enum.filter(events, &(&1.event_type == "RunSlotReleased"))
      assert released_events == []
    end

    test "waiter with terminal run → run_slots.remove_waiter dispatched", %{telemetry_ref: ref} do
      holder_run_id = unique_id("holder-run-waiter-test")
      orphan_waiter_run_id = unique_id("orphan-waiter-run")

      seed_live_run!(holder_run_id)
      seed_terminal_run!(orphan_waiter_run_id)
      # Append holder at v0, waiter at v1
      append_run_slot_holder!(holder_run_id, 0)
      append_run_slot_waiter!(orphan_waiter_run_id, 1)

      assert :ok = BootReconciliation.scan_run_slot_orphans()

      assert_eventually(fn ->
        case Store.read_stream_forward(@run_slots_stream, 0, 30) do
          {:ok, events} ->
            removed? =
              Enum.any?(events, fn
                %RecordedEvent{
                  event_type: "RunSlotWaiterRemoved",
                  data: %{run_id: ^orphan_waiter_run_id}
                } ->
                  true

                _ ->
                  false
              end)

            if removed?, do: :ok, else: {:still_waiting, removed?}

          other ->
            {:still_waiting, other}
        end
      end)

      assert_receive {[:foreman_server, :run_slots, :reconciled], ^ref,
                      %{holders_dropped: 0, waiters_dropped: 1}, %{phase: :boot}}
    end

    test "waiter with live run → no remove_waiter dispatched" do
      holder_run_id = unique_id("live-holder-run-waiter")
      live_waiter_run_id = unique_id("live-waiter-run")

      seed_live_run!(holder_run_id)
      seed_live_run!(live_waiter_run_id)
      append_run_slot_holder!(holder_run_id, 0)
      append_run_slot_waiter!(live_waiter_run_id, 1)

      assert :ok = BootReconciliation.scan_run_slot_orphans()

      Process.sleep(100)

      assert {:ok, events} = Store.read_stream_forward(@run_slots_stream, 0, 30)
      removed_events = Enum.filter(events, &(&1.event_type == "RunSlotWaiterRemoved"))
      assert removed_events == []
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

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
            end)
      }
    end)
  end

  defp append_run_slot_holder!(run_id, version) do
    :ok =
      Store.append_to_stream(@run_slots_stream, version, [
        %EventData{
          event_type: "RunSlotAcquired",
          data: %{
            run_id: run_id,
            capacity: 1,
            acquired_at_ms: System.system_time(:millisecond)
          },
          metadata: %{}
        }
      ])
  end

  defp append_run_slot_waiter!(run_id, version) do
    :ok =
      Store.append_to_stream(@run_slots_stream, version, [
        %EventData{
          event_type: "RunSlotQueued",
          data: %{
            run_id: run_id,
            position: 1,
            enqueued_at_ms: System.system_time(:millisecond)
          },
          metadata: %{}
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
    append_and_apply("run:#{run_id}", 0, "RunStarted", %{
      run_id: run_id,
      task_id: unique_id("task"),
      project_id: unique_id("project"),
      workflow_snapshot: %{},
      sequence: 0
    })

    append_and_apply("run:#{run_id}", 1, "RunCompleted", %{
      run_id: run_id,
      sequence: 1
    })
  end

  defp append_and_apply(stream_uuid, expected_version, event_type, payload) do
    :ok =
      Store.append_to_stream(stream_uuid, expected_version, [
        %EventData{event_type: event_type, data: payload, metadata: %{}}
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
