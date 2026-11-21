defmodule ForemanServer.Workflow.BootReconciliationSlotOrphanTest do
  use ExUnit.Case, async: false

  alias EventStore.RecordedEvent
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Workflow.BootReconciliation

  # The boot scan reads every project's `run_slots:<project_id>` stream (TRD-009); the legacy
  # `run_slots:global` stream is not swept (`RunSlotsMigration` only reads it).
  alias ForemanServer.Aggregates.RunSlots
  alias ForemanServer.TestSupport.CoordinatorHelpers, as: H

  setup_all do
    case Process.whereis(ForemanServer.Workflow.BootReconciliation) do
      nil -> start_supervised!({ForemanServer.Workflow.BootReconciliation, []})
      _ -> :ok
    end

    :ok
  end

  setup do
    ForemanServer.TestSupport.RunSlotsReset.reset!()

    on_exit(fn ->
      ForemanServer.TestSupport.RunSlotsReset.reset!()
    end)

    project = H.register_project(System.tmp_dir!(), config: %{})
    {:ok, project: project, stream: RunSlots.stream_id(project)}
  end

  describe "scan_run_slot_orphans/0" do
    test "holder whose run is absent is released and slot given to next live waiter", %{
      project: project,
      stream: stream
    } do
      holder_run_id = unique_id("absent-holder")
      waiter_run_id = unique_id("live-waiter")

      seed_live_run!(waiter_run_id, project)
      append_run_slot_holder!(project, holder_run_id, 0, 1)
      append_run_slot_waiter!(project, waiter_run_id, 1, 1)

      assert :ok = BootReconciliation.scan_run_slot_orphans()

      assert_eventually(fn ->
        with {:ok, events} <- Store.read_stream_forward(stream, 0, 20),
             %RecordedEvent{event_type: "RunSlotTransferred", data: data}
             when is_map(data) <- List.last(events) do
          released = Map.get(data, "released_run_id") || Map.get(data, :released_run_id)
          acquired = Map.get(data, "acquired_run_id") || Map.get(data, :acquired_run_id)

          if released == holder_run_id and acquired == waiter_run_id do
            :ok
          else
            {:still_waiting, List.last(events)}
          end
        else
          other -> {:still_waiting, other}
        end
      end)
    end

    test "holder whose run is terminal is released", %{project: project, stream: stream} do
      holder_run_id = unique_id("terminal-holder")

      seed_terminal_run!(holder_run_id, project)
      append_run_slot_holder!(project, holder_run_id, 0, 1)

      assert :ok = BootReconciliation.scan_run_slot_orphans()

      assert_eventually(fn ->
        with {:ok, events} <- Store.read_stream_forward(stream, 0, 20),
             %RecordedEvent{event_type: "RunSlotReleased", data: data}
             when is_map(data) <- List.last(events) do
          run_id_str = Map.get(data, "run_id") || Map.get(data, :run_id)

          if run_id_str == holder_run_id do
            :ok
          else
            {:still_waiting, List.last(events)}
          end
        else
          other -> {:still_waiting, other}
        end
      end)
    end

    test "waiter whose work was cancelled is removed and skipped", %{
      project: project,
      stream: stream
    } do
      holder_run_id = unique_id("live-holder")
      cancelled_waiter_run_id = unique_id("cancelled-waiter")
      live_waiter_run_id = unique_id("live-waiter")

      seed_live_run!(holder_run_id, project)
      seed_cancelled_run!(cancelled_waiter_run_id, project)
      seed_live_run!(live_waiter_run_id, project)

      append_run_slot_holder!(project, holder_run_id, 0, 1)
      append_run_slot_waiter!(project, cancelled_waiter_run_id, 1, 1)
      append_run_slot_waiter!(project, live_waiter_run_id, 2, 2)

      assert :ok = BootReconciliation.scan_run_slot_orphans()

      assert_eventually(fn ->
        with {:ok, events} <- Store.read_stream_forward(stream, 0, 30),
             true <-
               Enum.any?(events, fn
                 %RecordedEvent{
                   event_type: "RunSlotWaiterRemoved",
                   data: data
                 } ->
                   Map.get(data, "run_id") == cancelled_waiter_run_id or
                     Map.get(data, :run_id) == cancelled_waiter_run_id

                 _ ->
                   false
               end) do
          :ok
        else
          other -> {:still_waiting, other}
        end
      end)

      assert waiter_ids(project) == [live_waiter_run_id]
    end

    test "waiter list order is preserved after reconciliation", %{project: project} do
      holder_run_id = unique_id("live-holder")
      removed_waiter_run_id = unique_id("removed-waiter")
      waiter_two_run_id = unique_id("waiter-two")
      waiter_three_run_id = unique_id("waiter-three")

      seed_live_run!(holder_run_id, project)
      seed_terminal_run!(removed_waiter_run_id, project)
      seed_live_run!(waiter_two_run_id, project)
      seed_live_run!(waiter_three_run_id, project)

      append_run_slot_holder!(project, holder_run_id, 0, 1)
      append_run_slot_waiter!(project, removed_waiter_run_id, 1, 1)
      append_run_slot_waiter!(project, waiter_two_run_id, 2, 2)
      append_run_slot_waiter!(project, waiter_three_run_id, 3, 3)

      assert :ok = BootReconciliation.scan_run_slot_orphans()

      assert_eventually(fn ->
        case waiter_ids(project) do
          [^waiter_two_run_id, ^waiter_three_run_id] -> :ok
          other -> {:still_waiting, other}
        end
      end)
    end
  end

  defp waiter_ids(project) do
    {state, _version} =
      ForemanServer.Aggregate.load(RunSlots, RunSlots.stream_id(project))

    Enum.map(state.waiters, & &1.run_id)
  end

  defp unique_id(prefix) do
    "#{prefix}-slot-orphan-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
  end

  defp append_run_slot_holder!(project, run_id, version, capacity) do
    ForemanServer.CommandGateway.dispatch_system(%{
      type: "run_slots.acquire",
      aggregate_id: RunSlots.stream_id(project),
      command_id: "seed-holder:#{run_id}:#{version}",
      payload: %{
        run_id: run_id,
        project_id: project,
        capacity: capacity,
        acquired_at_ms: System.system_time(:millisecond)
      }
    })
  end

  defp append_run_slot_waiter!(project, run_id, version, _position) do
    ForemanServer.CommandGateway.dispatch_system(%{
      type: "run_slots.acquire",
      aggregate_id: RunSlots.stream_id(project),
      command_id: "seed-waiter:#{run_id}:#{version}",
      payload: %{
        run_id: run_id,
        project_id: project,
        capacity: 0,
        acquired_at_ms: System.system_time(:millisecond)
      }
    })
  end

  defp seed_live_run!(run_id, project) do
    append_and_apply("run:#{run_id}", 0, "RunStarted", %{
      run_id: run_id,
      task_id: unique_id("task"),
      project_id: project,
      workflow_snapshot: %{},
      sequence: 0
    })
  end

  defp seed_terminal_run!(run_id, project) do
    seed_live_run!(run_id, project)
    append_and_apply("run:#{run_id}", 1, "RunCompleted", %{run_id: run_id, sequence: 1})
  end

  defp seed_cancelled_run!(run_id, project) do
    seed_live_run!(run_id, project)

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
