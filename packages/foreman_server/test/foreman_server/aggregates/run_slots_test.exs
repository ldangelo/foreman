defmodule ForemanServer.Aggregates.RunSlotsTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.RunSlots
  alias ForemanServer.Aggregates.RunSlots.{State, Waiter}
  alias ForemanServer.EventCodec

  alias ForemanServer.Events.{
    RunSlotAcquired,
    RunSlotQueued,
    RunSlotReleased,
    RunSlotTransferred,
    RunSlotWaiterRemoved
  }

  describe "initial_state/0" do
    test "returns a state with nil capacity, empty holders map, and empty waiters list" do
      state = RunSlots.initial_state()

      assert state.capacity == nil
      assert state.holders == %{}
      assert state.waiters == []
    end
  end

  describe "apply_event — RunSlotAcquired" do
    test "adds run_id to holders map and sets capacity from event" do
      state = RunSlots.initial_state()
      event = %RunSlotAcquired{run_id: "run-1", capacity: 3, acquired_at_ms: 100}

      next = RunSlots.apply_event(state, event)

      assert next.capacity == 3
      assert %{"run-1" => %{acquired_at_ms: 100}} = next.holders
      assert next.waiters == []
    end

    test "adds multiple holders as capacity allows" do
      state =
        RunSlots.initial_state()
        |> apply_acquired("run-1", 3, 100)
        |> apply_acquired("run-2", 3, 101)
        |> apply_acquired("run-3", 3, 102)

      assert map_size(state.holders) == 3
      assert state.capacity == 3
      assert state.holders["run-1"].acquired_at_ms == 100
      assert state.holders["run-2"].acquired_at_ms == 101
      assert state.holders["run-3"].acquired_at_ms == 102
    end

    test "codec round-trip: decode → apply_event restores holders" do
      state = RunSlots.initial_state()
      data = %{"run_id" => "run-1", "capacity" => 3, "acquired_at_ms" => 100}

      struct = EventCodec.decode!("RunSlotAcquired", data)
      next = RunSlots.apply_event(state, struct)

      assert next.capacity == 3
      assert %{"run-1" => %{acquired_at_ms: 100}} = next.holders
    end
  end

  describe "apply_event — RunSlotQueued" do
    test "appends run_id to waiters list with correct enqueued_at_ms" do
      state = RunSlots.initial_state()
      event = %RunSlotQueued{run_id: "run-4", position: 1, enqueued_at_ms: 200}

      next = RunSlots.apply_event(state, event)

      assert [%Waiter{run_id: "run-4", enqueued_at_ms: 200}] = next.waiters
      assert next.capacity == nil
    end

    test "appends multiple waiters preserving FIFO order" do
      state =
        RunSlots.initial_state()
        |> apply_queued("run-4", 1, 200)
        |> apply_queued("run-5", 2, 201)
        |> apply_queued("run-6", 3, 202)

      assert [
               %Waiter{run_id: "run-4"},
               %Waiter{run_id: "run-5"},
               %Waiter{run_id: "run-6"}
             ] = state.waiters
    end

    test "codec round-trip: decode → apply_event appends waiter" do
      state = RunSlots.initial_state()
      data = %{"run_id" => "run-4", "position" => 1, "enqueued_at_ms" => 200}

      struct = EventCodec.decode!("RunSlotQueued", data)
      next = RunSlots.apply_event(state, struct)

      assert [%Waiter{run_id: "run-4", enqueued_at_ms: 200}] = next.waiters
    end
  end

  describe "apply_event — RunSlotReleased" do
    test "removes run_id from holders map" do
      state =
        RunSlots.initial_state()
        |> apply_acquired("run-1", 3, 100)
        |> apply_acquired("run-2", 3, 101)

      event = %RunSlotReleased{run_id: "run-1"}
      next = RunSlots.apply_event(state, event)

      assert Map.has_key?(next.holders, "run-1") == false
      assert %{"run-2" => %{acquired_at_ms: 101}} = next.holders
    end

    test "is idempotent when run_id is not a holder" do
      state =
        RunSlots.initial_state()
        |> apply_acquired("run-1", 3, 100)

      event = %RunSlotReleased{run_id: "nonexistent"}
      next = RunSlots.apply_event(state, event)

      assert next.holders == state.holders
    end

    test "codec round-trip: decode → apply_event clears holder" do
      state =
        RunSlots.initial_state()
        |> apply_acquired("run-1", 3, 100)

      data = %{"run_id" => "run-1"}
      struct = EventCodec.decode!("RunSlotReleased", data)
      next = RunSlots.apply_event(state, struct)

      assert next.holders == %{}
    end
  end

  describe "apply_event — RunSlotTransferred" do
    test "removes released_run_id from holders and promotes FIFO head as new holder" do
      state =
        RunSlots.initial_state()
        |> apply_acquired("run-1", 3, 100)
        |> apply_acquired("run-2", 3, 101)
        |> apply_queued("run-3", 1, 200)
        |> apply_queued("run-4", 2, 201)

      event = %RunSlotTransferred{
        released_run_id: "run-1",
        acquired_run_id: "run-3",
        acquired_at_ms: 300
      }

      next = RunSlots.apply_event(state, event)

      # run-1 is gone; run-3 is now a holder
      assert Map.has_key?(next.holders, "run-1") == false
      assert %{"run-2" => _, "run-3" => %{acquired_at_ms: 300}} = next.holders
      # run-4 is now the sole waiter (run-3 was promoted out of the queue)
      assert [%Waiter{run_id: "run-4"}] = next.waiters
    end

    test "is idempotent when released_run_id is not a holder" do
      state =
        RunSlots.initial_state()
        |> apply_acquired("run-1", 3, 100)
        |> apply_queued("run-2", 1, 200)

      event = %RunSlotTransferred{
        released_run_id: "nonexistent",
        acquired_run_id: "run-2",
        acquired_at_ms: 300
      }

      next = RunSlots.apply_event(state, event)

      # waiters is now empty — run-2 was the head and was promoted
      assert [] = next.waiters
    end

    test "codec round-trip: decode → apply_event promotes FIFO head" do
      state =
        RunSlots.initial_state()
        |> apply_acquired("run-1", 3, 100)
        |> apply_queued("run-2", 1, 200)

      data = %{
        "released_run_id" => "run-1",
        "acquired_run_id" => "run-2",
        "acquired_at_ms" => 300
      }

      struct = EventCodec.decode!("RunSlotTransferred", data)
      next = RunSlots.apply_event(state, struct)

      assert %{"run-2" => %{acquired_at_ms: 300}} = next.holders
      assert next.waiters == []
    end
  end

  describe "apply_event — RunSlotWaiterRemoved" do
    test "removes run_id from waiters list" do
      state =
        RunSlots.initial_state()
        |> apply_queued("run-4", 1, 200)
        |> apply_queued("run-5", 2, 201)
        |> apply_queued("run-6", 3, 202)

      event = %RunSlotWaiterRemoved{run_id: "run-5"}
      next = RunSlots.apply_event(state, event)

      assert [
               %Waiter{run_id: "run-4"},
               %Waiter{run_id: "run-6"}
             ] = next.waiters
    end

    test "is idempotent when run_id is not in waiters" do
      state =
        RunSlots.initial_state()
        |> apply_queued("run-4", 1, 200)

      event = %RunSlotWaiterRemoved{run_id: "nonexistent"}
      next = RunSlots.apply_event(state, event)

      assert next.waiters == state.waiters
    end

    test "codec round-trip: decode → apply_event drops waiter by run_id" do
      state =
        RunSlots.initial_state()
        |> apply_queued("run-4", 1, 200)
        |> apply_queued("run-5", 2, 201)

      data = %{"run_id" => "run-4"}
      struct = EventCodec.decode!("RunSlotWaiterRemoved", data)
      next = RunSlots.apply_event(state, struct)

      assert [%Waiter{run_id: "run-5"}] = next.waiters
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp apply_acquired(state, run_id, capacity, acquired_at_ms) do
    event = %RunSlotAcquired{run_id: run_id, capacity: capacity, acquired_at_ms: acquired_at_ms}
    RunSlots.apply_event(state, event)
  end

  defp apply_queued(state, run_id, position, enqueued_at_ms) do
    event = %RunSlotQueued{run_id: run_id, position: position, enqueued_at_ms: enqueued_at_ms}
    RunSlots.apply_event(state, event)
  end
end
