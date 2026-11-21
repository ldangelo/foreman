defmodule ForemanServer.ProjectionStoreRunSlotsTest do
  # Per-project run-slot fold (TRD-011): `RunSlot*` events are folded by their
  # `project_id` into `state.run_slots[project_id]`; `queue_status/1` reads one
  # project's slice. Events without a `project_id` are ignored.
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @now_ms 1_700_000_000_000

  setup_all do
    original = Application.get_env(:foreman_server, :projection_store_now_ms)
    Application.put_env(:foreman_server, :projection_store_now_ms, fn -> @now_ms end)

    on_exit(fn ->
      if original == nil,
        do: Application.delete_env(:foreman_server, :projection_store_now_ms),
        else: Application.put_env(:foreman_server, :projection_store_now_ms, original)
    end)

    :ok
  end

  setup do
    ProjectionStoreReset.reset!(keep_subscribers: true)
    on_exit(fn -> ProjectionStoreReset.reset!(keep_subscribers: true) end)
    :ok
  end

  defp apply!(events), do: :ok = ProjectionStore.apply_events(events)

  defp acquired(project, run, capacity \\ 3, at \\ 100),
    do: %{
      event_type: "RunSlotAcquired",
      payload: %{project_id: project, run_id: run, capacity: capacity, acquired_at_ms: at}
    }

  defp queued(project, run, position, at),
    do: %{
      event_type: "RunSlotQueued",
      payload: %{project_id: project, run_id: run, position: position, enqueued_at_ms: at}
    }

  defp waiting_ids(status), do: Enum.map(status.waiting, & &1.run_id)

  describe "initial state" do
    test "a project with no slot events has nothing running or waiting" do
      status = ProjectionStore.queue_status("p1")

      assert status.project_id == "p1"
      assert status.running == []
      assert status.waiting == []
      assert status.running_runs == 0
      assert status.waiting_runs == 0
    end
  end

  describe "RunSlotAcquired" do
    test "holders accumulate under their own project" do
      apply!([acquired("p1", "run-1"), acquired("p1", "run-2"), acquired("p1", "run-3")])

      status = ProjectionStore.queue_status("p1")
      assert Enum.sort(status.running) == ["run-1", "run-2", "run-3"]
      assert status.running_runs == 3
    end

    test "an acquisition drops the run from the waiters (raised limit / promotion)" do
      apply!([queued("p1", "run-2", 1, 200), queued("p1", "run-3", 2, 201)])
      apply!([acquired("p1", "run-2", 3, 300)])

      status = ProjectionStore.queue_status("p1")
      assert status.running == ["run-2"]
      assert waiting_ids(status) == ["run-3"]
    end
  end

  describe "RunSlotQueued" do
    test "waiters keep arrival (FIFO) order" do
      apply!([
        queued("p1", "run-4", 1, 200),
        queued("p1", "run-5", 2, 201),
        queued("p1", "run-6", 3, 202)
      ])

      assert waiting_ids(ProjectionStore.queue_status("p1")) == ["run-4", "run-5", "run-6"]
    end

    test "a run queued twice is listed once, keeping its first place" do
      apply!([
        queued("p1", "run-1", 1, 200),
        queued("p1", "run-2", 2, 201),
        queued("p1", "run-1", 3, 202)
      ])

      assert waiting_ids(ProjectionStore.queue_status("p1")) == ["run-1", "run-2"]
    end

    test "a run that then acquires a slot is running and no longer waiting" do
      apply!([
        queued("p1", "run-1", 1, 200),
        queued("p1", "run-2", 2, 201),
        acquired("p1", "run-1")
      ])

      status = ProjectionStore.queue_status("p1")
      assert status.running == ["run-1"]
      assert waiting_ids(status) == ["run-2"]
    end

    test "a run never appears in both holders and waiters, and a re-queue of a holder is not listed twice" do
      # The shape a paused-then-resumed waiting run left in the log before the fix: queued, queued
      # again, then acquired. Replay must leave it a holder only, in its own project only.
      apply!([
        queued("p1", "run-1", 1, 200),
        queued("p1", "run-1", 1, 201),
        acquired("p1", "run-1"),
        queued("p2", "run-1", 1, 202)
      ])

      p1 = ProjectionStore.queue_status("p1")
      assert p1.running == ["run-1"]
      assert p1.waiting == []

      p2 = ProjectionStore.queue_status("p2")
      assert p2.running == []
      assert waiting_ids(p2) == ["run-1"]
    end
  end

  describe "RunSlotReleased" do
    test "the holder leaves running" do
      apply!([
        acquired("p1", "run-1"),
        %{event_type: "RunSlotReleased", payload: %{project_id: "p1", run_id: "run-1"}}
      ])

      assert ProjectionStore.queue_status("p1").running == []
    end
  end

  describe "RunSlotTransferred" do
    test "old holder leaves, promoted waiter becomes a holder and leaves the queue" do
      apply!([
        acquired("p1", "run-1"),
        acquired("p1", "run-2"),
        acquired("p1", "run-3"),
        queued("p1", "run-4", 1, 200),
        queued("p1", "run-5", 2, 201),
        %{
          event_type: "RunSlotTransferred",
          payload: %{
            project_id: "p1",
            released_run_id: "run-1",
            acquired_run_id: "run-4",
            capacity: 3,
            acquired_at_ms: 300
          }
        }
      ])

      status = ProjectionStore.queue_status("p1")
      refute "run-1" in status.running
      assert "run-4" in status.running
      assert waiting_ids(status) == ["run-5"]
    end
  end

  describe "RunSlotWaiterRemoved" do
    test "the waiter leaves the queue and the others keep their order" do
      apply!([
        queued("p1", "run-4", 1, 200),
        queued("p1", "run-5", 2, 201),
        %{event_type: "RunSlotWaiterRemoved", payload: %{project_id: "p1", run_id: "run-4"}}
      ])

      assert waiting_ids(ProjectionStore.queue_status("p1")) == ["run-5"]
    end
  end

  describe "events without a project_id" do
    test "legacy (global-stream) slot events are ignored by every project" do
      apply!([
        %{
          event_type: "RunSlotAcquired",
          payload: %{run_id: "legacy-1", capacity: 3, acquired_at_ms: 100}
        },
        %{
          event_type: "RunSlotQueued",
          payload: %{run_id: "legacy-2", position: 1, enqueued_at_ms: 200}
        }
      ])

      status = ProjectionStore.queue_status("p1")
      assert status.running == []
      assert status.waiting == []
    end
  end

  # ---------------------------------------------------------------------------
  # RunSlotRecoveryAttempted
  # ---------------------------------------------------------------------------

  describe "apply_event — RunSlotRecoveryAttempted" do
    test "queue_status lists the latest entry per run as orphan_recovery" do
      assert ProjectionStore.queue_status("p1").orphan_recovery == []

      apply!([
        acquired("p1", "run-1", 5),
        recovery("p1", "run-1", "failed", 1, "slot_release"),
        recovery("p1", "run-1", "exhausted", 6, "slot_release"),
        queued("p1", "run-2", 1, 200),
        recovery("p1", "run-2", "failed", 2, "waiter_remove")
      ])

      assert ProjectionStore.queue_status("p1").orphan_recovery == [
               %{
                 run_id: "run-1",
                 attempt: 6,
                 outcome: "exhausted",
                 kind: "slot_release",
                 reason: "exit :killed",
                 elapsed_since_boot_ms: 6
               },
               %{
                 run_id: "run-2",
                 attempt: 2,
                 outcome: "failed",
                 kind: "waiter_remove",
                 reason: "exit :killed",
                 elapsed_since_boot_ms: 2
               }
             ]

      # Another project's queue lists none of them.
      assert ProjectionStore.queue_status("p2").orphan_recovery == []
    end

    test "dispatched, a release, a waiter removal and a transfer drop the entry" do
      apply!([
        acquired("p1", "run-1", 5),
        acquired("p1", "run-2", 5),
        queued("p1", "run-3", 1, 200),
        queued("p1", "run-4", 2, 201),
        recovery("p1", "run-1", "failed", 1, "slot_release"),
        recovery("p1", "run-2", "failed", 1, "slot_release"),
        recovery("p1", "run-3", "failed", 1, "waiter_remove"),
        recovery("p1", "run-4", "failed", 1, "waiter_remove")
      ])

      ids = fn -> ProjectionStore.queue_status("p1").orphan_recovery |> Enum.map(& &1.run_id) end
      assert ids.() == ["run-1", "run-2", "run-3", "run-4"]

      apply!([recovery("p1", "run-1", "dispatched", 0, "slot_release")])
      assert ids.() == ["run-2", "run-3", "run-4"]

      apply!([
        %{event_type: "RunSlotWaiterRemoved", payload: %{project_id: "p1", run_id: "run-4"}}
      ])

      assert ids.() == ["run-2", "run-3"]

      # run-2 releases and promotes run-3: both entries go.
      apply!([
        %{
          event_type: "RunSlotTransferred",
          payload: %{
            project_id: "p1",
            released_run_id: "run-2",
            acquired_run_id: "run-3",
            capacity: 5,
            acquired_at_ms: 300
          }
        }
      ])

      assert ids.() == []
    end

    test "a plain release drops the entry" do
      apply!([
        acquired("p1", "run-1", 5),
        recovery("p1", "run-1", "failed", 1, "slot_release"),
        %{event_type: "RunSlotReleased", payload: %{project_id: "p1", run_id: "run-1"}}
      ])

      assert ProjectionStore.queue_status("p1").orphan_recovery == []
    end

    test "a project's slots map without the recovery key folds and reports without crashing" do
      :sys.replace_state(ProjectionStore, fn state ->
        %{
          state
          | run_slots: %{"p1" => %{capacity: 2, holders: %{"run-1" => :held}, waiters: []}}
        }
      end)

      assert ProjectionStore.queue_status("p1").orphan_recovery == []

      apply!([
        recovery("p1", "run-1", "failed", 1, "slot_release"),
        %{event_type: "RunSlotReleased", payload: %{project_id: "p1", run_id: "run-1"}}
      ])

      status = ProjectionStore.queue_status("p1")
      assert status.running == []
      assert status.waiting == []
      assert status.orphan_recovery == []
    end
  end

  defp recovery(project, run_id, outcome, attempt, kind) do
    %{
      event_type: "RunSlotRecoveryAttempted",
      payload: %{
        project_id: project,
        run_id: run_id,
        attempt: attempt,
        outcome: outcome,
        kind: kind,
        reason: "exit :killed",
        elapsed_since_boot_ms: attempt
      }
    }
  end
end
