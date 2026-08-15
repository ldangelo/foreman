defmodule ForemanServer.Aggregates.RunSlotsReleaseTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.RunSlots
  alias ForemanServer.Aggregates.RunSlots.{State, Waiter}

  alias ForemanServer.Commands.{RunSlotsAcquire, RunSlotsRelease, RunSlotsRemoveWaiter}

  alias ForemanServer.Events.{
    RunSlotAcquired,
    RunSlotQueued,
    RunSlotReleased,
    RunSlotTransferred,
    RunSlotWaiterRemoved
  }

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @spec apply_acquired(RunSlots.State.t(), String.t(), non_neg_integer(), integer()) :: RunSlots.State.t()
  defp apply_acquired(state, run_id, capacity, acquired_at_ms) do
    event = %RunSlotAcquired{run_id: run_id, capacity: capacity, acquired_at_ms: acquired_at_ms}
    RunSlots.apply_event(state, event)
  end

  @spec apply_queued(RunSlots.State.t(), String.t(), pos_integer(), integer()) :: RunSlots.State.t()
  defp apply_queued(state, run_id, position, enqueued_at_ms) do
    event = %RunSlotQueued{run_id: run_id, position: position, enqueued_at_ms: enqueued_at_ms}
    RunSlots.apply_event(state, event)
  end

  # ---------------------------------------------------------------------------
  # handle_command — RunSlotsRelease
  # ---------------------------------------------------------------------------

  describe "handle_command — RunSlotsRelease" do
    test "emits RunSlotReleased when holder releases with no waiters" do
      state =
        RunSlots.initial_state()
        |> apply_acquired("run-1", 3, 100)

      cmd = %RunSlotsRelease{run_id: "run-1"}

      assert {:ok, %RunSlotReleased{run_id: "run-1", capacity: 3}} =
               RunSlots.handle_command(state, cmd)
    end

    test "emits RunSlotReleased with explicit capacity override" do
      state =
        RunSlots.initial_state()
        |> apply_acquired("run-1", 3, 100)

      cmd = %RunSlotsRelease{run_id: "run-1", capacity: 5}

      assert {:ok, %RunSlotReleased{run_id: "run-1", capacity: 5}} =
               RunSlots.handle_command(state, cmd)
    end


    test "emits RunSlotTransferred and promotes FIFO head when waiters present" do
      state =
        RunSlots.initial_state()
        |> apply_acquired("run-1", 2, 100)
        |> apply_acquired("run-2", 2, 101)
        |> apply_queued("run-3", 1, 200)
        |> apply_queued("run-4", 2, 201)

      cmd = %RunSlotsRelease{run_id: "run-1"}

      assert {:ok, %RunSlotTransferred{
        released_run_id: "run-1",
        acquired_run_id: "run-3",
        capacity: 2,
        acquired_at_ms: _
      }} = RunSlots.handle_command(state, cmd)
    end

    test "emits RunSlotTransferred with capacity override when waiters present" do
      state =
        RunSlots.initial_state()
        |> apply_acquired("run-1", 2, 100)
        |> apply_queued("run-2", 1, 200)

      cmd = %RunSlotsRelease{run_id: "run-1", capacity: 10}

      assert {:ok, %RunSlotTransferred{
        released_run_id: "run-1",
        acquired_run_id: "run-2",
        capacity: 10,
        acquired_at_ms: _
      }} = RunSlots.handle_command(state, cmd)
    end

    test "returns {:ok, nil} when run_id is not a holder (idempotent)" do
      state =
        RunSlots.initial_state()
        |> apply_acquired("run-1", 3, 100)

      cmd = %RunSlotsRelease{run_id: "nonexistent"}

      assert {:ok, nil} = RunSlots.handle_command(state, cmd)
    end

    test "returns {:ok, nil} when releasing a queued run that is not a holder" do
      state =
        RunSlots.initial_state()
        |> apply_acquired("run-1", 1, 100)
        |> apply_queued("run-2", 1, 200)

      cmd = %RunSlotsRelease{run_id: "run-2"}

      assert {:ok, nil} = RunSlots.handle_command(state, cmd)
    end
  end

  # ---------------------------------------------------------------------------
  # handle_command — RunSlotsRemoveWaiter
  # ---------------------------------------------------------------------------

  describe "handle_command — RunSlotsRemoveWaiter" do
    test "emits RunSlotWaiterRemoved when run_id is in waiters list" do
      state =
        RunSlots.initial_state()
        |> apply_acquired("run-1", 2, 100)
        |> apply_queued("run-2", 1, 200)
        |> apply_queued("run-3", 2, 201)

      cmd = %RunSlotsRemoveWaiter{run_id: "run-2"}

      assert {:ok, %RunSlotWaiterRemoved{run_id: "run-2"}} =
               RunSlots.handle_command(state, cmd)
    end

    test "removes only the targeted waiter, preserving others" do
      state =
        RunSlots.initial_state()
        |> apply_acquired("run-1", 1, 100)
        |> apply_queued("run-2", 1, 200)
        |> apply_queued("run-3", 2, 201)

      cmd = %RunSlotsRemoveWaiter{run_id: "run-3"}

      assert {:ok, %RunSlotWaiterRemoved{run_id: "run-3"}} =
               RunSlots.handle_command(state, cmd)
    end

    test "returns {:ok, nil} when run_id is not in waiters list (idempotent)" do
      state =
        RunSlots.initial_state()
        |> apply_acquired("run-1", 2, 100)
        |> apply_queued("run-2", 1, 200)

      cmd = %RunSlotsRemoveWaiter{run_id: "nonexistent"}

      assert {:ok, nil} = RunSlots.handle_command(state, cmd)
    end

    test "returns {:ok, nil} when trying to remove a holder from waiters (not in waiters)" do
      state =
        RunSlots.initial_state()
        |> apply_acquired("run-1", 3, 100)

      cmd = %RunSlotsRemoveWaiter{run_id: "run-1"}

      assert {:ok, nil} = RunSlots.handle_command(state, cmd)
    end
  end

  # ---------------------------------------------------------------------------
  # apply_event — RunSlotTransferred (promotes FIFO head, removes from waiters)
  # ---------------------------------------------------------------------------

  describe "apply_event — RunSlotTransferred" do
    test "promoted run_id is in holders, released run_id is removed" do
      state =
        RunSlots.initial_state()
        |> apply_acquired("run-1", 3, 100)
        |> apply_acquired("run-2", 3, 101)
        |> apply_queued("run-3", 1, 200)

      event = %RunSlotTransferred{
        released_run_id: "run-1",
        acquired_run_id: "run-3",
        acquired_at_ms: 300
      }

      next = RunSlots.apply_event(state, event)

      refute Map.has_key?(next.holders, "run-1")
      assert %{"run-2" => _, "run-3" => %{acquired_at_ms: 300}} = next.holders
    end

    test "promoted waiter is removed from waiters list" do
      state =
        RunSlots.initial_state()
        |> apply_acquired("run-1", 3, 100)
        |> apply_queued("run-2", 1, 200)
        |> apply_queued("run-3", 2, 201)

      event = %RunSlotTransferred{
        released_run_id: "run-1",
        acquired_run_id: "run-2",
        acquired_at_ms: 300
      }

      next = RunSlots.apply_event(state, event)

      # run-2 (the promoted head) is removed from waiters
      assert [%Waiter{run_id: "run-3"}] = next.waiters
    end

    test "is idempotent when released_run_id is not in holders" do
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

      # released_run_id not in holders: holders unchanged except for acquired_run_id added
      assert %{"run-1" => _, "run-2" => %{acquired_at_ms: 300}} = next.holders
      # run-2 (acquired_run_id) was head and is removed from waiters
      assert next.waiters == []
    end
  end
end
