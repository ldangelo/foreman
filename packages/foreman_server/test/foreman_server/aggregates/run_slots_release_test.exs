defmodule ForemanServer.Aggregates.RunSlotsReleaseTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.RunSlots
  alias ForemanServer.Aggregates.RunSlots.Waiter

  alias ForemanServer.Commands.{RunSlotsRelease, RunSlotsRemoveWaiter}

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

  @spec apply_acquired(RunSlots.State.t(), String.t(), non_neg_integer(), integer()) ::
          RunSlots.State.t()
  defp apply_acquired(state, run_id, capacity, acquired_at_ms) do
    event = %RunSlotAcquired{run_id: run_id, capacity: capacity, acquired_at_ms: acquired_at_ms}
    RunSlots.apply_event(state, event)
  end

  @spec apply_queued(RunSlots.State.t(), String.t(), pos_integer(), integer()) ::
          RunSlots.State.t()
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

      assert {:ok,
              %RunSlotTransferred{
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

      assert {:ok,
              %RunSlotTransferred{
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

  # ---------------------------------------------------------------------------
  # TRD-002: release promotes only while holders < capacity (AC-003-4)
  # ---------------------------------------------------------------------------

  @spec apply_decision(RunSlots.State.t(), struct()) :: RunSlots.State.t()
  defp apply_decision(state, event), do: RunSlots.apply_event(state, event)

  defp release_env(run_id, capacity, reason \\ "run_completed") do
    %{
      type: "run_slots.release",
      command_id: "test:release:#{run_id}",
      aggregate_id: RunSlots.stream_id("proj-a"),
      payload: %{run_id: run_id, capacity: capacity, reason: reason}
    }
  end

  describe "release with a lowered limit (AC-003-4)" do
    test "waiter stays queued until holders fall below the lowered capacity" do
      state =
        RunSlots.initial_state()
        |> apply_acquired("h1", 4, 1)
        |> apply_acquired("h2", 4, 2)
        |> apply_acquired("h3", 4, 3)
        |> apply_acquired("h4", 4, 4)
        |> apply_queued("w1", 1, 10)

      # limit lowered to 2: 4 -> 3 and 3 -> 2 holders are not below 2
      assert {:ok, %RunSlotReleased{run_id: "h1", capacity: 2}} =
               ev1 = RunSlots.handle_command(state, release_env("h1", 2))

      state = apply_decision(state, elem(ev1, 1))
      assert [%Waiter{run_id: "w1"}] = state.waiters

      assert {:ok, %RunSlotReleased{run_id: "h2"}} =
               ev2 = RunSlots.handle_command(state, release_env("h2", 2))

      state = apply_decision(state, elem(ev2, 1))
      assert map_size(state.holders) == 2
      assert [%Waiter{run_id: "w1"}] = state.waiters

      # third release leaves 1 holder, which is below 2: waiter is promoted
      assert {:ok, %RunSlotTransferred{released_run_id: "h3", acquired_run_id: "w1"}} =
               RunSlots.handle_command(state, release_env("h3", 2))
    end

    test "holders at capacity and a waiter: release promotes the waiter" do
      state =
        RunSlots.initial_state()
        |> apply_acquired("h1", 2, 1)
        |> apply_acquired("h2", 2, 2)
        |> apply_queued("w1", 1, 10)

      assert {:ok, %RunSlotTransferred{released_run_id: "h1", acquired_run_id: "w1", capacity: 2}} =
               RunSlots.handle_command(state, release_env("h1", 2))
    end

    test "typed release command honours a lowered capacity too" do
      state =
        RunSlots.initial_state()
        |> apply_acquired("h1", 3, 1)
        |> apply_acquired("h2", 3, 2)
        |> apply_acquired("h3", 3, 3)
        |> apply_queued("w1", 1, 10)

      assert {:ok, %RunSlotReleased{run_id: "h1", capacity: 1}} =
               RunSlots.handle_command(state, %RunSlotsRelease{run_id: "h1", capacity: 1})
    end
  end

  # ---------------------------------------------------------------------------
  # TRD-002: a freed slot goes to the same project (AC-006-1)
  # ---------------------------------------------------------------------------

  describe "release is per project stream (AC-006-1)" do
    test "an A release promotes only A's waiter; B's state is untouched" do
      a =
        RunSlots.initial_state()
        |> apply_acquired("a1", 1, 1)
        |> apply_queued("a-wait", 1, 10)

      b =
        RunSlots.initial_state()
        |> apply_acquired("b1", 1, 2)
        |> apply_queued("b-wait", 1, 11)

      assert {:ok, %RunSlotTransferred{acquired_run_id: "a-wait"}} =
               RunSlots.handle_command(a, release_env("a1", 1))

      # A's release envelope cannot affect B: B does not hold a1 and stays as is
      assert {:ok, nil} = RunSlots.handle_command(b, release_env("a1", 1))
      assert [%Waiter{run_id: "b-wait"}] = b.waiters
    end

    test "release_command targets the project's own stream and carries the project id" do
      cmd_a = RunSlots.release_command("proj-a", "run-1", "run_completed")
      cmd_b = RunSlots.release_command("proj-b", "run-1", "run_completed")

      assert cmd_a.type == "run_slots.release"
      assert cmd_a.aggregate_id == RunSlots.stream_id("proj-a")
      assert cmd_b.aggregate_id == RunSlots.stream_id("proj-b")
      assert cmd_a.payload.run_id == "run-1"
      assert cmd_a.payload.project_id == "proj-a"
      assert cmd_a.payload.reason == "run_completed"
      assert is_integer(cmd_a.payload.capacity) and cmd_a.payload.capacity >= 1
    end

    test "release_command ids are unique per call" do
      a = RunSlots.release_command("proj-a", "run-1", "run_completed")
      b = RunSlots.release_command("proj-a", "run-1", "run_completed")
      refute a.command_id == b.command_id
    end
  end

  # ---------------------------------------------------------------------------
  # TRD-002: every terminal reason releases (AC-006-2)
  # ---------------------------------------------------------------------------

  describe "every terminal reason releases (AC-006-2)" do
    @terminal_reasons ~w(run_completed run_failed run_blocked run_cancelled run_flagged_stuck run_deleted)

    test "release_command for each terminal reason frees the holder" do
      for reason <- @terminal_reasons do
        state =
          RunSlots.initial_state()
          |> apply_acquired("run-1", 2, 1)

        cmd = RunSlots.release_command("proj-a", "run-1", reason)

        assert {:ok, %RunSlotReleased{run_id: "run-1"}} = RunSlots.handle_command(state, cmd),
               "reason #{reason} did not release"
      end
    end

    test "the dispatcher routes all six terminal event types to slot release" do
      source =
        File.read!(Path.expand("../../../lib/foreman_server/workflow/dispatcher.ex", __DIR__))

      [_, list] = Regex.run(~r/@run_terminated_event_types ~w\(([^)]*)\)/, source)
      types = String.split(list)

      for t <- ~w(RunCompleted RunFailed RunBlocked RunCancelled RunFlaggedStuck RunDeleted) do
        assert t in types
      end

      assert source =~ "terminate_slot(run_id, reason)"
    end
  end

  # ---------------------------------------------------------------------------
  # TRD-002: only RunSlots.release_command/3 builds the release envelope
  # ---------------------------------------------------------------------------

  describe "source contract: one release envelope builder" do
    test "no production module outside RunSlots hand-builds a run_slots.release envelope" do
      lib = Path.expand("../../../lib", __DIR__)

      offenders =
        lib
        |> Path.join("**/*.ex")
        |> Path.wildcard()
        |> Enum.reject(&String.ends_with?(&1, "aggregates/run_slots.ex"))
        |> Enum.filter(fn path ->
          File.read!(path) =~ ~r/type:\s*"run_slots\.release"/
        end)
        |> Enum.map(&Path.relative_to(&1, lib))

      assert offenders == []
    end

    test "the four callers use RunSlots.release_command/3" do
      lib = Path.expand("../../../lib/foreman_server", __DIR__)

      for rel <-
            ~w(run_admission.ex workflow/dispatcher.ex run_lifecycle_reconciler.ex workflow/boot_reconciliation.ex) do
        assert File.read!(Path.join(lib, rel)) =~ "RunSlots.release_command(",
               "#{rel} does not use RunSlots.release_command/3"
      end
    end
  end
end
