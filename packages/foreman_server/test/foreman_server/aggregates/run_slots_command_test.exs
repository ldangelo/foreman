defmodule ForemanServer.Aggregates.RunSlotsCommandTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.RunSlots
  alias ForemanServer.Aggregates.RunSlots.{State, Waiter}

  alias ForemanServer.Commands.RunSlotsAcquire

  alias ForemanServer.Events.{
    RunSlotAcquired,
    RunSlotQueued
  }

  describe "handle_command — RunSlotsAcquire" do
    test "emits RunSlotAcquired when holders < capacity (empty holders, capacity 3)" do
      state = %State{capacity: nil, holders: %{}, waiters: []}
      cmd = %RunSlotsAcquire{run_id: "run-1", capacity: 3}

      assert {:ok, %RunSlotAcquired{run_id: "run-1", capacity: 3, acquired_at_ms: _}} =
               RunSlots.handle_command(state, cmd)
    end

    test "emits RunSlotAcquired when holders < capacity (partial fill)" do
      state = %State{
        capacity: 3,
        holders: %{
          "run-1" => %{acquired_at_ms: 1_000_000}
        },
        waiters: []
      }

      cmd = %RunSlotsAcquire{run_id: "run-2", capacity: 3}

      assert {:ok, %RunSlotAcquired{run_id: "run-2", capacity: 3, acquired_at_ms: _}} =
               RunSlots.handle_command(state, cmd)
    end

    test "returns {:ok, nil} (idempotent no-op) when run_id already in holders" do
      state = %State{
        capacity: 3,
        holders: %{
          "run-1" => %{acquired_at_ms: 1_000_000}
        },
        waiters: []
      }

      cmd = %RunSlotsAcquire{run_id: "run-1", capacity: 3}

      assert {:ok, nil} = RunSlots.handle_command(state, cmd)
    end

    test "emits RunSlotQueued with correct position when holders == capacity" do
      state = %State{
        capacity: 2,
        holders: %{
          "run-1" => %{acquired_at_ms: 1_000_000},
          "run-2" => %{acquired_at_ms: 1_000_001}
        },
        waiters: []
      }

      cmd = %RunSlotsAcquire{run_id: "run-3", capacity: 2}

      assert {:ok, %RunSlotQueued{run_id: "run-3", position: 1, enqueued_at_ms: _}} =
               RunSlots.handle_command(state, cmd)
    end

    test "emits RunSlotQueued with correct position when waiters already exist" do
      state = %State{
        capacity: 1,
        holders: %{
          "run-1" => %{acquired_at_ms: 1_000_000}
        },
        waiters: [
          %Waiter{run_id: "run-2", enqueued_at_ms: 1_000_002}
        ]
      }

      cmd = %RunSlotsAcquire{run_id: "run-3", capacity: 1}

      assert {:ok, %RunSlotQueued{run_id: "run-3", position: 2, enqueued_at_ms: _}} =
               RunSlots.handle_command(state, cmd)
    end
  end

  describe "a run that is already a waiter acquires again" do
    # A paused waiting run is released (a no-op for a non-holder) but stays a waiter, and
    # RunAdmission.acquire_slot_for_resume/2 acquires again with a fresh command id.
    test "at full capacity it is not queued a second time" do
      state = %State{
        capacity: 1,
        holders: %{"run-1" => %{acquired_at_ms: 1_000_000}},
        waiters: [%Waiter{run_id: "run-2", enqueued_at_ms: 1_000_002}]
      }

      result = RunSlots.handle_command(state, %RunSlotsAcquire{run_id: "run-2", capacity: 1})

      assert {:ok, nil} = result
      assert Enum.count(apply_result(state, result).waiters, &(&1.run_id == "run-2")) == 1
    end

    test "when a slot is free it leaves the waiter list instead of being in both" do
      state = %State{
        capacity: 2,
        holders: %{"run-1" => %{acquired_at_ms: 1_000_000}},
        waiters: [%Waiter{run_id: "run-2", enqueued_at_ms: 1_000_002}]
      }

      result = RunSlots.handle_command(state, %RunSlotsAcquire{run_id: "run-2", capacity: 2})
      after_state = apply_result(state, result)

      assert Map.has_key?(after_state.holders, "run-2")
      refute Enum.any?(after_state.waiters, &(&1.run_id == "run-2"))
    end
  end

  describe "a waiter that acquires again behind an older waiter (per-project FIFO)" do
    test "it does not jump the queue when a slot is free: still one place, not a holder" do
      state = %State{
        capacity: 2,
        holders: %{"run-1" => %{acquired_at_ms: 1_000_000}},
        waiters: [
          %Waiter{run_id: "run-2", enqueued_at_ms: 1_000_002},
          %Waiter{run_id: "run-3", enqueued_at_ms: 1_000_003}
        ]
      }

      result = RunSlots.handle_command(state, %RunSlotsAcquire{run_id: "run-3", capacity: 2})
      after_state = apply_result(state, result)

      assert {:ok, nil} = result
      refute Map.has_key?(after_state.holders, "run-3")
      assert Enum.map(after_state.waiters, & &1.run_id) == ["run-2", "run-3"]
    end
  end

  defp apply_result(state, {:ok, nil}), do: state
  defp apply_result(state, {:ok, event}), do: RunSlots.apply_event(state, event)
end
