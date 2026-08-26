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
end
