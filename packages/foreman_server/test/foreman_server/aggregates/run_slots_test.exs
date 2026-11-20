defmodule ForemanServer.Aggregates.RunSlotsTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.RunSlots
  alias ForemanServer.Aggregates.RunSlots.Waiter
  alias ForemanServer.EventCodec

  alias ForemanServer.Events.{
    RunSlotAcquired,
    RunSlotQueued,
    RunSlotRecoveryAttempted,
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
      assert state.recovery == %{}
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

  describe "apply_event — RunSlotRecoveryAttempted (boot cleanup budget)" do
    test "failed and exhausted write the entry; the latest attempt wins" do
      state =
        RunSlots.initial_state()
        |> apply_acquired("run-1", 3, 100)
        |> apply_recovery("run-1", "failed", 3, "slot_release", "exit :killed", 40)
        |> apply_recovery("run-1", "failed", 4, "slot_release", "exit :killed", 90)

      assert state.recovery == %{
               "run-1" => %{
                 attempt: 4,
                 outcome: "failed",
                 kind: "slot_release",
                 reason: "exit :killed",
                 elapsed_since_boot_ms: 90
               }
             }

      exhausted = apply_recovery(state, "run-1", "exhausted", 6, "slot_release", nil, 120)
      assert %{"run-1" => %{attempt: 6, outcome: "exhausted", reason: nil}} = exhausted.recovery
    end

    test "dispatched deletes the entry, and only that run's" do
      state =
        RunSlots.initial_state()
        |> apply_acquired("run-1", 3, 100)
        |> apply_acquired("run-2", 3, 101)
        |> apply_recovery("run-1", "failed", 1, "slot_release", nil, 1)
        |> apply_recovery("run-2", "failed", 2, "slot_release", nil, 2)
        |> apply_recovery("run-1", "dispatched", 0, "slot_release", nil, 3)

      assert Map.keys(state.recovery) == ["run-2"]
    end

    test "a release, a waiter removal and a transfer each take the run's entry with it" do
      base =
        RunSlots.initial_state()
        |> apply_acquired("run-1", 1, 100)
        |> apply_queued("run-2", 1, 200)
        |> apply_queued("run-3", 2, 201)
        |> apply_recovery("run-1", "failed", 1, "slot_release", nil, 1)
        |> apply_recovery("run-2", "failed", 2, "waiter_remove", nil, 2)
        |> apply_recovery("run-3", "failed", 3, "waiter_remove", nil, 3)

      assert Map.keys(base.recovery) |> Enum.sort() == ["run-1", "run-2", "run-3"]

      released = RunSlots.apply_event(base, %RunSlotReleased{run_id: "run-1"})
      assert Map.keys(released.recovery) |> Enum.sort() == ["run-2", "run-3"]

      removed = RunSlots.apply_event(base, %RunSlotWaiterRemoved{run_id: "run-3"})
      assert Map.keys(removed.recovery) |> Enum.sort() == ["run-1", "run-2"]

      # Transfer: the released holder's entry and the promoted waiter's entry both go.
      transferred =
        RunSlots.apply_event(base, %RunSlotTransferred{
          released_run_id: "run-1",
          acquired_run_id: "run-2",
          acquired_at_ms: 300
        })

      assert Map.keys(transferred.recovery) == ["run-3"]
    end

    test "replay through Aggregate.load/2's RecordedEvent shape and the codec agree" do
      data = %{
        "run_id" => "run-1",
        "attempt" => 2,
        "outcome" => "failed",
        "kind" => "waiter_remove",
        "reason" => "exit :killed",
        "elapsed_since_boot_ms" => 55
      }

      typed =
        RunSlots.apply_event(
          RunSlots.initial_state(),
          EventCodec.decode!("RunSlotRecoveryAttempted", data)
        )

      recorded =
        RunSlots.apply_event(
          RunSlots.initial_state(),
          %EventStore.RecordedEvent{event_type: "RunSlotRecoveryAttempted", data: data}
        )

      assert typed.recovery == recorded.recovery

      assert typed.recovery["run-1"] == %{
               attempt: 2,
               outcome: "failed",
               kind: "waiter_remove",
               reason: "exit :killed",
               elapsed_since_boot_ms: 55
             }

      dispatched = Map.put(data, "outcome", "dispatched")

      cleared =
        RunSlots.apply_event(
          typed,
          %EventStore.RecordedEvent{event_type: "RunSlotRecoveryAttempted", data: dispatched}
        )

      assert cleared.recovery == %{}
    end
  end

  describe "replayed events (Aggregate.load/2's RecordedEvent shape) take the run's recovery entry" do
    setup do
      base =
        RunSlots.initial_state()
        |> apply_acquired("run-1", 1, 100)
        |> apply_queued("run-2", 1, 200)
        |> apply_queued("run-3", 2, 201)
        |> apply_recovery("run-1", "failed", 1, "slot_release", nil, 1)
        |> apply_recovery("run-2", "failed", 2, "waiter_remove", nil, 2)
        |> apply_recovery("run-3", "failed", 3, "waiter_remove", nil, 3)

      %{base: base}
    end

    test "RunSlotReleased", %{base: base} do
      next = replay(base, "RunSlotReleased", %{"run_id" => "run-1"})
      assert Map.keys(next.recovery) |> Enum.sort() == ["run-2", "run-3"]
    end

    test "RunSlotWaiterRemoved", %{base: base} do
      next = replay(base, "RunSlotWaiterRemoved", %{"run_id" => "run-3"})
      assert Map.keys(next.recovery) |> Enum.sort() == ["run-1", "run-2"]
    end

    test "RunSlotTransferred takes both the released and the acquired run's entry", %{base: base} do
      next =
        replay(base, "RunSlotTransferred", %{
          "released_run_id" => "run-1",
          "acquired_run_id" => "run-2",
          "acquired_at_ms" => 300
        })

      assert Map.keys(next.recovery) == ["run-3"]
    end
  end

  describe "handle_command — run_slots.recovery_attempt" do
    setup do
      %{
        state:
          RunSlots.initial_state()
          |> apply_acquired("run-1", 2, 100)
          |> apply_queued("run-2", 1, 200)
      }
    end

    test "records a failure or exhaustion for a holder and for a waiter", %{state: state} do
      assert {:ok,
              %RunSlotRecoveryAttempted{
                run_id: "run-1",
                attempt: 6,
                outcome: "exhausted",
                kind: "slot_release",
                reason: "boom",
                elapsed_since_boot_ms: 12
              }} =
               recovery_command(state,
                 run_id: "run-1",
                 attempt: 6,
                 outcome: "exhausted",
                 reason: "boom"
               )

      assert {:ok, %RunSlotRecoveryAttempted{run_id: "run-2", kind: "waiter_remove"}} =
               recovery_command(state, run_id: "run-2", kind: "waiter_remove")
    end

    test "appends nothing for a failure or exhaustion when the run no longer holds or waits", %{
      state: state
    } do
      assert {:ok, nil} = recovery_command(state, run_id: "run-9")

      assert {:ok, nil} =
               recovery_command(state, run_id: "run-9", outcome: "exhausted", attempt: 6)
    end

    test "dispatched needs no membership because it follows the release", %{state: state} do
      assert {:ok, %RunSlotRecoveryAttempted{outcome: "dispatched", attempt: 0}} =
               recovery_command(state, run_id: "run-9", outcome: "dispatched", attempt: 0)
    end

    test "rejects invalid fields", %{state: state} do
      for {field, value} <- [
            run_id: "",
            attempt: -1,
            attempt: "1",
            outcome: "blocked",
            kind: "other",
            elapsed_since_boot_ms: -5,
            elapsed_since_boot_ms: nil,
            reason: 42
          ] do
        assert {:error, {:missing_or_invalid, ^field}} =
                 recovery_command(state, [{field, value}])
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp replay(state, event_type, data) do
    RunSlots.apply_event(state, %EventStore.RecordedEvent{event_type: event_type, data: data})
  end

  defp recovery_command(state, overrides) do
    payload =
      Map.merge(
        %{
          run_id: "run-1",
          attempt: 1,
          outcome: "failed",
          kind: "slot_release",
          elapsed_since_boot_ms: 12
        },
        Map.new(overrides)
      )

    RunSlots.handle_command(state, %{type: "run_slots.recovery_attempt", payload: payload})
  end

  defp apply_recovery(state, run_id, outcome, attempt, kind, reason, elapsed) do
    RunSlots.apply_event(state, %RunSlotRecoveryAttempted{
      run_id: run_id,
      attempt: attempt,
      outcome: outcome,
      kind: kind,
      reason: reason,
      elapsed_since_boot_ms: elapsed
    })
  end

  defp apply_acquired(state, run_id, capacity, acquired_at_ms) do
    event = %RunSlotAcquired{run_id: run_id, capacity: capacity, acquired_at_ms: acquired_at_ms}
    RunSlots.apply_event(state, event)
  end

  defp apply_queued(state, run_id, position, enqueued_at_ms) do
    event = %RunSlotQueued{run_id: run_id, position: position, enqueued_at_ms: enqueued_at_ms}
    RunSlots.apply_event(state, event)
  end
end
