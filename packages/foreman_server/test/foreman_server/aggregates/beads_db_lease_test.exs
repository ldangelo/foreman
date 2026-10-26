defmodule ForemanServer.Aggregates.BeadsDbLeaseTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.BeadsDbLease
  alias ForemanServer.Aggregates.BeadsDbLease.{Holder, State, Waiter}
  alias ForemanServer.EventCodec

  describe "initial_state/0" do
    test "returns a non-existent state with no holder and no waiters" do
      state = BeadsDbLease.initial_state()

      assert state.exists? == false
      assert state.db_path == nil
      assert state.holder == nil
      assert state.waiters == []
    end
  end

  describe "stream_id/1" do
    test "builds canonical beads_db_lease: prefix" do
      assert BeadsDbLease.stream_id("/tmp/foo.db") == "beads_db_lease:/tmp/foo.db"
    end
  end

  describe "lease.acquire" do
    test "emits BeadsDbLeaseAcquired when lease is free" do
      state = BeadsDbLease.initial_state()
      cmd = acquire_cmd("/tmp/a.db", "run-1", "task-1", 100)

      assert {:ok, event_spec} = BeadsDbLease.handle_command(state, cmd)
      assert event_spec.event_type == "BeadsDbLeaseAcquired"
      assert event_spec.payload.db_path == "/tmp/a.db"
      assert event_spec.payload.run_id == "run-1"
      assert event_spec.payload.task_id == "task-1"
      assert event_spec.payload.acquired_at_ms == 100
      assert event_spec.payload.provenance == {:direct, "run-1"}
    end

    test "is a no-op when same run_id already holds the lease" do
      state =
        BeadsDbLease.initial_state()
        |> apply_acquire("/tmp/a.db", "run-1", "task-1", 100)

      cmd = acquire_cmd("/tmp/a.db", "run-1", "task-1", 200)
      assert {:ok, nil} = BeadsDbLease.handle_command(state, cmd)
    end

    test "atomically enqueues as a waiter when held by a different run" do
      state =
        BeadsDbLease.initial_state()
        |> apply_acquire("/tmp/a.db", "run-1", "task-1", 100)

      cmd = acquire_cmd("/tmp/a.db", "run-2", "task-2", 150)
      assert {:ok, event_spec} = BeadsDbLease.handle_command(state, cmd)
      assert event_spec.event_type == "BeadsDbLeaseWaiterRegistered"
      assert event_spec.payload.run_id == "run-2"
      assert event_spec.payload.task_id == "task-2"
      assert event_spec.payload.enqueued_at_ms == 150
    end

    test "enqueues the same run_id exactly once when re-attempting" do
      state =
        BeadsDbLease.initial_state()
        |> apply_acquire("/tmp/a.db", "run-1", "task-1", 100)
        |> apply_waiter("/tmp/a.db", "run-2", "task-2", 150)

      assert length(state.waiters) == 1

      cmd = acquire_cmd("/tmp/a.db", "run-2", "task-2", 175)
      assert {:ok, nil} = BeadsDbLease.handle_command(state, cmd)
    end

    test "rejects acquire with missing payload fields" do
      state = BeadsDbLease.initial_state()

      assert {:error, {:missing_or_invalid, :db_path}} =
               BeadsDbLease.handle_command(state, %{
                 type: "lease.acquire",
                 payload: %{run_id: "r", task_id: "t", acquired_at_ms: 1}
               })

      assert {:error, {:missing_or_invalid, :run_id}} =
               BeadsDbLease.handle_command(state, %{
                 type: "lease.acquire",
                 payload: %{db_path: "/p", task_id: "t", acquired_at_ms: 1}
               })
    end
  end

  describe "lease.release" do
    test "is a no-op when the lease is free" do
      state = BeadsDbLease.initial_state()
      cmd = release_cmd("/tmp/a.db", "run-1", 100, :run_completed)
      assert {:ok, nil} = BeadsDbLease.handle_command(state, cmd)
    end

    test "is a no-op when a different run_id tries to release" do
      state =
        BeadsDbLease.initial_state()
        |> apply_acquire("/tmp/a.db", "run-1", "task-1", 100)

      cmd = release_cmd("/tmp/a.db", "run-foreign", 200, :run_completed)
      assert {:ok, nil} = BeadsDbLease.handle_command(state, cmd)

      assert state.holder.run_id == "run-1"
    end

    test "emits BeadsDbLeaseReleased when holder releases and no waiters are queued" do
      state =
        BeadsDbLease.initial_state()
        |> apply_acquire("/tmp/a.db", "run-1", "task-1", 100)

      cmd = release_cmd("/tmp/a.db", "run-1", 200, :run_completed)
      assert {:ok, event_spec} = BeadsDbLease.handle_command(state, cmd)
      assert event_spec.event_type == "BeadsDbLeaseReleased"
      assert event_spec.payload.reason == :run_completed
      assert event_spec.payload.released_at_ms == 200
    end

    test "emits BeadsDbLeaseTransferred promoting head waiter when one is queued" do
      state =
        BeadsDbLease.initial_state()
        |> apply_acquire("/tmp/a.db", "run-1", "task-1", 100)
        |> apply_waiter("/tmp/a.db", "run-2", "task-2", 150)
        |> apply_waiter("/tmp/a.db", "run-3", "task-3", 175)

      cmd = release_cmd("/tmp/a.db", "run-1", 200, :run_completed)
      assert {:ok, event_spec} = BeadsDbLease.handle_command(state, cmd)
      assert event_spec.event_type == "BeadsDbLeaseTransferred"
      assert event_spec.payload.released_run_id == "run-1"
      assert event_spec.payload.acquired_run_id == "run-2"
      assert event_spec.payload.acquired_task_id == "task-2"
      assert event_spec.payload.acquired_at_ms == 150
    end
  end

  describe "lease.remove_waiter" do
    test "removes a queued waiter by run_id" do
      state =
        BeadsDbLease.initial_state()
        |> apply_acquire("/tmp/a.db", "run-1", "task-1", 100)
        |> apply_waiter("/tmp/a.db", "run-2", "task-2", 150)
        |> apply_waiter("/tmp/a.db", "run-3", "task-3", 175)

      cmd = remove_waiter_cmd("/tmp/a.db", "run-2", 200, :run_cancelled)
      assert {:ok, event_spec} = BeadsDbLease.handle_command(state, cmd)
      assert event_spec.event_type == "BeadsDbLeaseWaiterRemoved"
      assert event_spec.payload.run_id == "run-2"
      assert event_spec.payload.reason == :run_cancelled

      next = BeadsDbLease.apply_event(state, event_spec)
      assert [%Waiter{run_id: "run-3"}] = BeadsDbLease.waiters(next)
    end

    test "is a no-op when no waiter with that run_id is queued" do
      state =
        BeadsDbLease.initial_state()
        |> apply_acquire("/tmp/a.db", "run-1", "task-1", 100)

      cmd = remove_waiter_cmd("/tmp/a.db", "run-absent", 200, :run_cancelled)
      assert {:ok, nil} = BeadsDbLease.handle_command(state, cmd)
    end

    test "rejects remove_waiter with missing payload fields" do
      state = BeadsDbLease.initial_state()

      assert {:error, {:missing_or_invalid, :db_path}} =
               BeadsDbLease.handle_command(state, %{
                 type: "lease.remove_waiter",
                 payload: %{run_id: "r", removed_at_ms: 1}
               })
    end

    test "cancel-before-promotion: cancelled waiter is not promoted on release" do
      state =
        BeadsDbLease.initial_state()
        |> apply_acquire("/tmp/a.db", "run-1", "task-1", 100)
        |> apply_waiter("/tmp/a.db", "run-2", "task-2", 150)

      {:ok, remove_spec} =
        BeadsDbLease.handle_command(
          state,
          remove_waiter_cmd("/tmp/a.db", "run-2", 175, :run_cancelled)
        )

      state_after_remove = BeadsDbLease.apply_event(state, remove_spec)
      assert state_after_remove.waiters == []

      # Now the holder releases — there must be NO waiter promotion, so
      # release returns a Released (no waiters) rather than a Transferred.
      cmd = release_cmd("/tmp/a.db", "run-1", 200, :run_completed)
      assert {:ok, event_spec} = BeadsDbLease.handle_command(state_after_remove, cmd)
      assert event_spec.event_type == "BeadsDbLeaseReleased"
      assert event_spec.payload.run_id == "run-1"
    end

    test "cancel-before-promotion: head waiter removed, next waiter is promoted" do
      state =
        BeadsDbLease.initial_state()
        |> apply_acquire("/tmp/a.db", "run-1", "task-1", 100)
        |> apply_waiter("/tmp/a.db", "run-2", "task-2", 150)
        |> apply_waiter("/tmp/a.db", "run-3", "task-3", 175)

      {:ok, remove_spec} =
        BeadsDbLease.handle_command(
          state,
          remove_waiter_cmd("/tmp/a.db", "run-2", 200, :run_cancelled)
        )

      state_after_remove = BeadsDbLease.apply_event(state, remove_spec)
      assert [%Waiter{run_id: "run-3"}] = BeadsDbLease.waiters(state_after_remove)

      cmd = release_cmd("/tmp/a.db", "run-1", 250, :run_completed)
      assert {:ok, event_spec} = BeadsDbLease.handle_command(state_after_remove, cmd)
      assert event_spec.event_type == "BeadsDbLeaseTransferred"
      assert event_spec.payload.acquired_run_id == "run-3"
      assert event_spec.payload.acquired_task_id == "task-3"
    end

    test "removing the head waiter after the holder has released prevents promotion race" do
      # Holder releases, runs through Transferred for run-2.
      # run-2 is cancelled before any code observes the new holder.
      # That sequence is itself a race; in our aggregate the
      # holder already moved. This test pins down that a follow-up
      # remove_waiter against the now-current holder (run-2)
      # is a clean no-op.
      state =
        BeadsDbLease.initial_state()
        |> apply_acquire("/tmp/a.db", "run-1", "task-1", 100)
        |> apply_waiter("/tmp/a.db", "run-2", "task-2", 150)

      {:ok, transfer_spec} =
        BeadsDbLease.handle_command(
          state,
          release_cmd("/tmp/a.db", "run-1", 200, :run_completed)
        )

      state_after_transfer = BeadsDbLease.apply_event(state, transfer_spec)
      assert %Holder{run_id: "run-2"} = state_after_transfer.holder

      cmd = remove_waiter_cmd("/tmp/a.db", "run-2", 250, :run_cancelled)
      # run-2 is now the holder, not a queued waiter — removal is a no-op.
      assert {:ok, nil} = BeadsDbLease.handle_command(state_after_transfer, cmd)
    end
  end

  describe "apply_event round-trip via EventCodec" do
    test "BeadsDbLeaseAcquired decode → apply_event restores holder" do
      data = %{
        "db_path" => "/tmp/a.db",
        "run_id" => "run-1",
        "task_id" => "task-1",
        "acquired_at_ms" => 100
      }

      struct = EventCodec.decode!("BeadsDbLeaseAcquired", data)
      state = BeadsDbLease.apply_event(BeadsDbLease.initial_state(), struct)

      assert %State{db_path: "/tmp/a.db", holder: %Holder{run_id: "run-1"}} = state
    end

    test "BeadsDbLeaseWaiterRegistered decode → apply_event appends waiter" do
      data = %{
        "db_path" => "/tmp/a.db",
        "run_id" => "run-2",
        "task_id" => "task-2",
        "enqueued_at_ms" => 150
      }

      struct = EventCodec.decode!("BeadsDbLeaseWaiterRegistered", data)
      state = BeadsDbLease.apply_event(BeadsDbLease.initial_state(), struct)

      assert [%Waiter{run_id: "run-2"}] = state.waiters
    end

    test "BeadsDbLeaseReleased decode → apply_event clears holder" do
      started =
        BeadsDbLease.initial_state()
        |> apply_acquire("/tmp/a.db", "run-1", "task-1", 100)

      data = %{
        "db_path" => "/tmp/a.db",
        "run_id" => "run-1",
        "released_at_ms" => 200,
        "reason" => :run_completed
      }

      struct = EventCodec.decode!("BeadsDbLeaseReleased", data)
      state = BeadsDbLease.apply_event(started, struct)

      assert state.holder == nil
      assert state.db_path == "/tmp/a.db"
    end

    test "BeadsDbLeaseWaiterRemoved decode → apply_event drops waiter by run_id" do
      state =
        BeadsDbLease.initial_state()
        |> apply_acquire("/tmp/a.db", "run-1", "task-1", 100)
        |> apply_waiter("/tmp/a.db", "run-2", "task-2", 150)
        |> apply_waiter("/tmp/a.db", "run-3", "task-3", 175)

      data = %{
        "db_path" => "/tmp/a.db",
        "run_id" => "run-2",
        "removed_at_ms" => 200,
        "reason" => :run_cancelled
      }

      struct = EventCodec.decode!("BeadsDbLeaseWaiterRemoved", data)
      next = BeadsDbLease.apply_event(state, struct)

      assert [%Waiter{run_id: "run-3"}] = BeadsDbLease.waiters(next)
    end

    test "BeadsDbLeaseTransferred decode → apply_event swaps holder + drops head waiter" do
      started =
        BeadsDbLease.initial_state()
        |> apply_acquire("/tmp/a.db", "run-1", "task-1", 100)
        |> apply_waiter("/tmp/a.db", "run-2", "task-2", 150)
        |> apply_waiter("/tmp/a.db", "run-3", "task-3", 175)

      data = %{
        "db_path" => "/tmp/a.db",
        "released_run_id" => "run-1",
        "released_at_ms" => 200,
        "reason" => :run_completed,
        "acquired_run_id" => "run-2",
        "acquired_task_id" => "task-2",
        "acquired_at_ms" => 150,
        "enqueued_at_ms" => 150
      }

      struct = EventCodec.decode!("BeadsDbLeaseTransferred", data)
      state = BeadsDbLease.apply_event(started, struct)

      assert %Holder{run_id: "run-2", task_id: "task-2"} = state.holder
      assert [%Waiter{run_id: "run-3"}] = state.waiters
    end

    test "codec rejects an unknown payload key on decode (regression)" do
      data = %{
        "db_path" => "/tmp/a.db",
        "run_id" => "run-1",
        "task_id" => "task-1",
        "acquired_at_ms" => 100,
        "enqueued_behind" => "run-0"
      }

      assert_raise ArgumentError, ~r/EventCodec/, fn ->
        EventCodec.decode!("BeadsDbLeaseAcquired", data)
      end
    end
  end

  describe "server incarnations" do
    test "lease.acquire records the caller's incarnation on the holder and on a waiter" do
      state =
        BeadsDbLease.initial_state()
        |> apply_acquire("/tmp/a.db", "run-1", "task-1", 100, "boot-a")
        |> apply_waiter("/tmp/a.db", "run-2", "task-2", 150, "boot-a")

      assert %Holder{run_id: "run-1", incarnation: "boot-a"} = state.holder
      assert [%Waiter{run_id: "run-2", incarnation: "boot-a"}] = state.waiters
    end

    test "a hold taken without an incarnation stays run-scoped" do
      state =
        BeadsDbLease.initial_state()
        |> apply_acquire("/tmp/a.db", "run-1", "task-1", 100)

      assert %Holder{run_id: "run-1", incarnation: nil} = state.holder
    end

    test "rejects an incarnation that is not a non-empty string" do
      cmd = put_in(acquire_cmd("/tmp/a.db", "run-1", "task-1", 100), [:payload, :incarnation], 7)

      assert {:error, {:missing_or_invalid, :incarnation}} =
               BeadsDbLease.handle_command(BeadsDbLease.initial_state(), cmd)
    end

    test "an acquirer takes the lease over from a holder of another incarnation and leaves the queue alone" do
      state =
        BeadsDbLease.initial_state()
        |> apply_acquire("/tmp/a.db", "watcher:p:1", "watcher:p:1", 100, "boot-old")
        |> apply_waiter("/tmp/a.db", "run-q", "task-q", 120, "boot-old")

      cmd = acquire_cmd("/tmp/a.db", "watcher:p:2", "watcher:p:2", 200, "boot-new")

      assert {:ok, event_spec} = BeadsDbLease.handle_command(state, cmd)
      assert event_spec.event_type == "BeadsDbLeaseAcquired"
      assert event_spec.payload.provenance == {:reclaimed_stale_holder, "watcher:p:1"}
      assert event_spec.payload.incarnation == "boot-new"

      next = BeadsDbLease.apply_event(state, event_spec)
      assert %Holder{run_id: "watcher:p:2", incarnation: "boot-new"} = next.holder
      assert [%Waiter{run_id: "run-q"}] = next.waiters
    end

    test "an acquirer queues behind a holder of its own incarnation" do
      state =
        BeadsDbLease.initial_state()
        |> apply_acquire("/tmp/a.db", "watcher:p:1", "watcher:p:1", 100, "boot-new")

      cmd = acquire_cmd("/tmp/a.db", "watcher:p:2", "watcher:p:2", 200, "boot-new")

      assert {:ok, event_spec} = BeadsDbLease.handle_command(state, cmd)
      assert event_spec.event_type == "BeadsDbLeaseWaiterRegistered"
      assert event_spec.payload.incarnation == "boot-new"
    end

    test "a hold that belongs to a run is never taken over, whatever incarnation asks" do
      state =
        BeadsDbLease.initial_state()
        |> apply_acquire("/tmp/a.db", "run-1", "task-1", 100)

      cmd = acquire_cmd("/tmp/a.db", "watcher:p:2", "watcher:p:2", 200, "boot-new")

      assert {:ok, %{event_type: "BeadsDbLeaseWaiterRegistered"}} =
               BeadsDbLease.handle_command(state, cmd)
    end

    test "an acquirer that names no incarnation cannot tell a hold is dead, so it queues" do
      state =
        BeadsDbLease.initial_state()
        |> apply_acquire("/tmp/a.db", "watcher:p:1", "watcher:p:1", 100, "boot-old")

      cmd = acquire_cmd("/tmp/a.db", "run-2", "task-2", 200)

      assert {:ok, %{event_type: "BeadsDbLeaseWaiterRegistered"}} =
               BeadsDbLease.handle_command(state, cmd)
    end

    test "the run that holds the lease claims its own hold when it acquires under another incarnation" do
      state =
        BeadsDbLease.initial_state()
        |> apply_acquire("/tmp/a.db", "run-1", "task-1", 100, "boot-old")

      same = acquire_cmd("/tmp/a.db", "run-1", "task-1", 150, "boot-old")
      assert {:ok, nil} = BeadsDbLease.handle_command(state, same)

      # Left tagged "boot-old", the next acquirer of the new boot would take the lease
      # from under the call this run is about to make.
      cmd = acquire_cmd("/tmp/a.db", "run-1", "task-1", 200, "boot-new")
      assert {:ok, event_spec} = BeadsDbLease.handle_command(state, cmd)
      assert event_spec.event_type == "BeadsDbLeaseAcquired"
      assert event_spec.payload.provenance == {:direct, "run-1"}

      claimed = BeadsDbLease.apply_event(state, event_spec)
      assert %Holder{run_id: "run-1", incarnation: "boot-new"} = claimed.holder

      other = acquire_cmd("/tmp/a.db", "watcher:p:2", "watcher:p:2", 250, "boot-new")

      assert {:ok, %{event_type: "BeadsDbLeaseWaiterRegistered"}} =
               BeadsDbLease.handle_command(claimed, other)
    end

    test "queueing again under another incarnation re-tags the waiter and keeps its place" do
      # Two runs queued under the old boot; a call of the new boot has since taken the lease over.
      state =
        BeadsDbLease.initial_state()
        |> apply_acquire("/tmp/a.db", "run-1", "task-1", 100, "boot-old")
        |> apply_waiter("/tmp/a.db", "run-2", "task-2", 150, "boot-old")
        |> apply_waiter("/tmp/a.db", "run-3", "task-3", 175, "boot-old")
        |> apply_acquire("/tmp/a.db", "watcher:p:1", "watcher:p:1", 200, "boot-new")

      cmd = acquire_cmd("/tmp/a.db", "run-2", "task-2", 250, "boot-new")
      assert {:ok, event_spec} = BeadsDbLease.handle_command(state, cmd)
      assert event_spec.event_type == "BeadsDbLeaseWaiterRegistered"

      state = BeadsDbLease.apply_event(state, event_spec)

      assert [
               %Waiter{run_id: "run-2", enqueued_at_ms: 150, incarnation: "boot-new"},
               %Waiter{run_id: "run-3", incarnation: "boot-old"}
             ] = state.waiters

      # Queued under this boot already: nothing more to record.
      assert {:ok, nil} = BeadsDbLease.handle_command(state, cmd)
    end

    test "promotion hands the waiter's incarnation to the new holder" do
      state =
        BeadsDbLease.initial_state()
        |> apply_acquire("/tmp/a.db", "run-1", "task-1", 100, "boot-a")
        |> apply_waiter("/tmp/a.db", "run-2", "task-2", 150, "boot-a")

      cmd = release_cmd("/tmp/a.db", "run-1", 200, :run_completed)
      assert {:ok, event_spec} = BeadsDbLease.handle_command(state, cmd)
      assert event_spec.event_type == "BeadsDbLeaseTransferred"
      assert event_spec.payload.acquired_incarnation == "boot-a"

      next = BeadsDbLease.apply_event(state, event_spec)
      assert %Holder{run_id: "run-2", incarnation: "boot-a"} = next.holder
    end

    test "the typed events carry the incarnation through EventCodec into apply_event" do
      acquired =
        EventCodec.decode!("BeadsDbLeaseAcquired", %{
          "db_path" => "/tmp/a.db",
          "run_id" => "run-1",
          "task_id" => "task-1",
          "acquired_at_ms" => 100,
          "incarnation" => "boot-a"
        })

      registered =
        EventCodec.decode!("BeadsDbLeaseWaiterRegistered", %{
          "db_path" => "/tmp/a.db",
          "run_id" => "run-2",
          "task_id" => "task-2",
          "enqueued_at_ms" => 150,
          "incarnation" => "boot-b"
        })

      transferred =
        EventCodec.decode!("BeadsDbLeaseTransferred", %{
          "db_path" => "/tmp/a.db",
          "released_run_id" => "run-1",
          "released_at_ms" => 200,
          "reason" => :run_completed,
          "acquired_run_id" => "run-2",
          "acquired_task_id" => "task-2",
          "acquired_at_ms" => 150,
          "enqueued_at_ms" => 150,
          "acquired_incarnation" => "boot-b"
        })

      state = BeadsDbLease.apply_event(BeadsDbLease.initial_state(), acquired)
      assert %Holder{incarnation: "boot-a"} = state.holder

      state = BeadsDbLease.apply_event(state, registered)
      assert [%Waiter{run_id: "run-2", incarnation: "boot-b"}] = state.waiters

      state = BeadsDbLease.apply_event(state, transferred)
      assert %Holder{run_id: "run-2", incarnation: "boot-b"} = state.holder
    end

    test "events stored before incarnations existed replay as holds without one" do
      stored = %EventStore.RecordedEvent{
        event_type: "BeadsDbLeaseAcquired",
        data: %{
          db_path: "/tmp/a.db",
          run_id: "run-1",
          task_id: "task-1",
          acquired_at_ms: 100,
          provenance: {:direct, "run-1"}
        }
      }

      state = BeadsDbLease.apply_event(BeadsDbLease.initial_state(), stored)

      assert %Holder{run_id: "run-1", incarnation: nil} = state.holder
    end
  end

  describe "holder/1 + waiters/1 accessors" do
    test "returns the current holder" do
      state =
        BeadsDbLease.initial_state()
        |> apply_acquire("/tmp/a.db", "run-1", "task-1", 100)

      assert %Holder{run_id: "run-1", task_id: "task-1"} = BeadsDbLease.holder(state)
    end

    test "returns nil when the lease is free" do
      assert BeadsDbLease.holder(BeadsDbLease.initial_state()) == nil
    end

    test "returns the FIFO waiter list" do
      state =
        BeadsDbLease.initial_state()
        |> apply_acquire("/tmp/a.db", "run-1", "task-1", 100)
        |> apply_waiter("/tmp/a.db", "run-2", "task-2", 150)
        |> apply_waiter("/tmp/a.db", "run-3", "task-3", 175)

      assert [%Waiter{run_id: "run-2"}, %Waiter{run_id: "run-3"}] =
               BeadsDbLease.waiters(state)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp acquire_cmd(db_path, run_id, task_id, acquired_at_ms, incarnation \\ nil) do
    payload = %{
      db_path: db_path,
      run_id: run_id,
      task_id: task_id,
      acquired_at_ms: acquired_at_ms
    }

    %{
      type: "lease.acquire",
      payload: if(incarnation, do: Map.put(payload, :incarnation, incarnation), else: payload)
    }
  end

  defp release_cmd(db_path, run_id, released_at_ms, reason) do
    %{
      type: "lease.release",
      payload: %{
        db_path: db_path,
        run_id: run_id,
        released_at_ms: released_at_ms,
        reason: reason
      }
    }
  end

  defp remove_waiter_cmd(db_path, run_id, removed_at_ms, reason) do
    %{
      type: "lease.remove_waiter",
      payload: %{
        db_path: db_path,
        run_id: run_id,
        removed_at_ms: removed_at_ms,
        reason: reason
      }
    }
  end

  defp apply_acquire(state, db_path, run_id, task_id, at, incarnation \\ nil) do
    cmd = acquire_cmd(db_path, run_id, task_id, at, incarnation)
    {:ok, event_spec} = BeadsDbLease.handle_command(state, cmd)
    assert event_spec.event_type == "BeadsDbLeaseAcquired"
    BeadsDbLease.apply_event(state, event_spec)
  end

  defp apply_waiter(state, db_path, run_id, task_id, enqueued_at, incarnation \\ nil) do
    cmd = acquire_cmd(db_path, run_id, task_id, enqueued_at, incarnation)
    {:ok, event_spec} = BeadsDbLease.handle_command(state, cmd)
    assert event_spec.event_type == "BeadsDbLeaseWaiterRegistered"
    BeadsDbLease.apply_event(state, event_spec)
  end
end
