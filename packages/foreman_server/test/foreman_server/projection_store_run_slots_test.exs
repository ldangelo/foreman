defmodule ProjectionStoreRunSlotsTestHelper do
  def reset_projection_store do
    ForemanServer.TestSupport.ProjectionStoreReset.reset!(keep_subscribers: true)
  end

  def set_now_ms(now_ms) when is_integer(now_ms) do
    Process.put(:projection_store_now_ms, fn -> now_ms end)
  end

  def clear_now_ms do
    Process.delete(:projection_store_now_ms)
  end
end

defmodule ForemanServer.ProjectionStoreRunSlotsTest do
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore

  @default_now_ms 1_700_000_000_000

  setup_all do
    original_now_ms = Application.get_env(:foreman_server, :projection_store_now_ms)
    Application.put_env(:foreman_server, :projection_store_now_ms, fn -> @default_now_ms end)

    on_exit(fn ->
      if original_now_ms == nil do
        Application.delete_env(:foreman_server, :projection_store_now_ms)
      else
        Application.put_env(:foreman_server, :projection_store_now_ms, original_now_ms)
      end
    end)

    :ok
  end

  setup do
    ProjectionStoreRunSlotsTestHelper.reset_projection_store()
    ProjectionStoreRunSlotsTestHelper.set_now_ms(@default_now_ms)

    on_exit(fn ->
      ProjectionStoreRunSlotsTestHelper.clear_now_ms()
      ProjectionStoreRunSlotsTestHelper.reset_projection_store()
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Initial state
  # ---------------------------------------------------------------------------

  describe "initial state" do
    test "empty holders and waiters" do
      status = ProjectionStore.queue_status()

      assert status.capacity == 0
      assert status.running == []
      assert status.waiting == []
    end
  end

  # ---------------------------------------------------------------------------
  # RunSlotAcquired
  # ---------------------------------------------------------------------------

  describe "apply_event — RunSlotAcquired" do
    test "holder appears in running list" do
      events = [
        %{
          event_type: "RunSlotAcquired",
          payload: %{run_id: "run-1", capacity: 3, acquired_at_ms: 100}
        }
      ]

      :ok = ProjectionStore.apply_events(events)

      status = ProjectionStore.queue_status()
      assert status.capacity == 3
      assert status.running == ["run-1"]
      assert status.waiting == []
    end

    test "multiple holders accumulated" do
      events = [
        %{
          event_type: "RunSlotAcquired",
          payload: %{run_id: "run-1", capacity: 3, acquired_at_ms: 100}
        },
        %{
          event_type: "RunSlotAcquired",
          payload: %{run_id: "run-2", capacity: 3, acquired_at_ms: 101}
        },
        %{
          event_type: "RunSlotAcquired",
          payload: %{run_id: "run-3", capacity: 3, acquired_at_ms: 102}
        }
      ]

      :ok = ProjectionStore.apply_events(events)

      status = ProjectionStore.queue_status()
      assert status.capacity == 3
      assert length(status.running) == 3
      assert "run-1" in status.running
      assert "run-2" in status.running
      assert "run-3" in status.running
    end
  end

  # ---------------------------------------------------------------------------
  # RunSlotQueued
  # ---------------------------------------------------------------------------

  describe "apply_event — RunSlotQueued" do
    test "run_id appears in waiting list in FIFO order" do
      events = [
        %{
          event_type: "RunSlotQueued",
          payload: %{run_id: "run-4", position: 1, enqueued_at_ms: 200}
        },
        %{
          event_type: "RunSlotQueued",
          payload: %{run_id: "run-5", position: 2, enqueued_at_ms: 201}
        },
        %{
          event_type: "RunSlotQueued",
          payload: %{run_id: "run-6", position: 3, enqueued_at_ms: 202}
        }
      ]

      :ok = ProjectionStore.apply_events(events)

      status = ProjectionStore.queue_status()
      assert status.waiting == ["run-4", "run-5", "run-6"]
    end
  end

  # ---------------------------------------------------------------------------
  # RunSlotReleased
  # ---------------------------------------------------------------------------

  describe "apply_event — RunSlotReleased" do
    test "holder removed from running" do
      events = [
        %{
          event_type: "RunSlotAcquired",
          payload: %{run_id: "run-1", capacity: 3, acquired_at_ms: 100}
        },
        %{event_type: "RunSlotReleased", payload: %{run_id: "run-1"}}
      ]

      :ok = ProjectionStore.apply_events(events)

      status = ProjectionStore.queue_status()
      assert status.running == []
      assert status.capacity == 3
    end
  end

  # ---------------------------------------------------------------------------
  # RunSlotTransferred
  # ---------------------------------------------------------------------------

  describe "apply_event — RunSlotTransferred" do
    test "old holder removed, new holder added, promoted waiter removed" do
      events = [
        %{
          event_type: "RunSlotAcquired",
          payload: %{run_id: "run-1", capacity: 3, acquired_at_ms: 100}
        },
        %{
          event_type: "RunSlotAcquired",
          payload: %{run_id: "run-2", capacity: 3, acquired_at_ms: 101}
        },
        %{
          event_type: "RunSlotAcquired",
          payload: %{run_id: "run-3", capacity: 3, acquired_at_ms: 102}
        },
        %{
          event_type: "RunSlotQueued",
          payload: %{run_id: "run-4", position: 1, enqueued_at_ms: 200}
        },
        %{
          event_type: "RunSlotQueued",
          payload: %{run_id: "run-5", position: 2, enqueued_at_ms: 201}
        },
        # run-1 releases and run-4 (FIFO head) is promoted
        %{
          event_type: "RunSlotTransferred",
          payload: %{released_run_id: "run-1", acquired_run_id: "run-4", acquired_at_ms: 300}
        }
      ]

      :ok = ProjectionStore.apply_events(events)

      status = ProjectionStore.queue_status()
      refute "run-1" in status.running
      assert "run-4" in status.running
      assert status.waiting == ["run-5"]
    end
  end

  # ---------------------------------------------------------------------------
  # RunSlotWaiterRemoved
  # ---------------------------------------------------------------------------

  describe "apply_event — RunSlotWaiterRemoved" do
    test "waiter removed from waiting list" do
      events = [
        %{
          event_type: "RunSlotQueued",
          payload: %{run_id: "run-4", position: 1, enqueued_at_ms: 200}
        },
        %{
          event_type: "RunSlotQueued",
          payload: %{run_id: "run-5", position: 2, enqueued_at_ms: 201}
        },
        %{event_type: "RunSlotWaiterRemoved", payload: %{run_id: "run-4"}}
      ]

      :ok = ProjectionStore.apply_events(events)

      status = ProjectionStore.queue_status()
      assert status.waiting == ["run-5"]
    end
  end

  # ---------------------------------------------------------------------------
  # queue_status/0
  # ---------------------------------------------------------------------------

  describe "queue_status/0" do
    test "returns correct structure" do
      events = [
        %{
          event_type: "RunSlotAcquired",
          payload: %{run_id: "run-1", capacity: 5, acquired_at_ms: 100}
        },
        %{
          event_type: "RunSlotAcquired",
          payload: %{run_id: "run-2", capacity: 5, acquired_at_ms: 101}
        },
        %{
          event_type: "RunSlotQueued",
          payload: %{run_id: "run-3", position: 1, enqueued_at_ms: 200}
        },
        %{
          event_type: "RunSlotQueued",
          payload: %{run_id: "run-4", position: 2, enqueued_at_ms: 201}
        }
      ]

      :ok = ProjectionStore.apply_events(events)

      status = ProjectionStore.queue_status()

      assert %{
               capacity: 5,
               running: [_ | _],
               waiting: [_ | _]
             } = status

      assert status.capacity == 5
      assert Enum.sort(status.running) == Enum.sort(["run-1", "run-2"])
      assert status.waiting == ["run-3", "run-4"]
    end
  end

  # ---------------------------------------------------------------------------
  # RunSlotRecoveryAttempted
  # ---------------------------------------------------------------------------

  describe "apply_event — RunSlotRecoveryAttempted" do
    test "queue_status lists the latest entry per run as orphan_recovery" do
      assert ProjectionStore.queue_status().orphan_recovery == []

      :ok =
        ProjectionStore.apply_events([
          acquired("run-1"),
          recovery("run-1", "failed", 1, "slot_release"),
          recovery("run-1", "exhausted", 6, "slot_release"),
          queued("run-2"),
          recovery("run-2", "failed", 2, "waiter_remove")
        ])

      assert ProjectionStore.queue_status().orphan_recovery == [
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
    end

    test "dispatched, a release, a waiter removal and a transfer drop the entry" do
      :ok =
        ProjectionStore.apply_events([
          acquired("run-1"),
          acquired("run-2"),
          queued("run-3"),
          queued("run-4"),
          recovery("run-1", "failed", 1, "slot_release"),
          recovery("run-2", "failed", 1, "slot_release"),
          recovery("run-3", "failed", 1, "waiter_remove"),
          recovery("run-4", "failed", 1, "waiter_remove")
        ])

      ids = fn -> ProjectionStore.queue_status().orphan_recovery |> Enum.map(& &1.run_id) end
      assert ids.() == ["run-1", "run-2", "run-3", "run-4"]

      :ok = ProjectionStore.apply_events([recovery("run-1", "dispatched", 0, "slot_release")])
      assert ids.() == ["run-2", "run-3", "run-4"]

      :ok =
        ProjectionStore.apply_events([
          %{event_type: "RunSlotWaiterRemoved", payload: %{run_id: "run-4"}}
        ])

      assert ids.() == ["run-2", "run-3"]

      # run-2 releases and promotes run-3: both entries go.
      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "RunSlotTransferred",
            payload: %{
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
      :ok =
        ProjectionStore.apply_events([
          acquired("run-1"),
          recovery("run-1", "failed", 1, "slot_release"),
          %{event_type: "RunSlotReleased", payload: %{run_id: "run-1"}}
        ])

      assert ProjectionStore.queue_status().orphan_recovery == []
    end

    test "a run_slots map without the recovery key folds and reports without crashing" do
      :sys.replace_state(ProjectionStore, fn state ->
        %{state | run_slots: %{capacity: 2, holders: %{"run-1" => :held}, waiters: []}}
      end)

      assert ProjectionStore.queue_status().orphan_recovery == []

      :ok =
        ProjectionStore.apply_events([
          recovery("run-1", "failed", 1, "slot_release"),
          %{event_type: "RunSlotReleased", payload: %{run_id: "run-1"}}
        ])

      assert ProjectionStore.queue_status() ==
               %{capacity: 2, running: [], waiting: [], orphan_recovery: []}
    end
  end

  defp acquired(run_id) do
    %{
      event_type: "RunSlotAcquired",
      payload: %{run_id: run_id, capacity: 5, acquired_at_ms: 100}
    }
  end

  defp queued(run_id) do
    %{event_type: "RunSlotQueued", payload: %{run_id: run_id, position: 1, enqueued_at_ms: 200}}
  end

  defp recovery(run_id, outcome, attempt, kind) do
    %{
      event_type: "RunSlotRecoveryAttempted",
      payload: %{
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
