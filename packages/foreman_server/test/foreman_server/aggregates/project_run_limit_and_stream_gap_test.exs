defmodule ForemanServer.ProjectRunLimitTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.ProjectRunLimit

  defp limit_state(count) do
    %ProjectRunLimit.State{
      exists?: true,
      project_id: "p",
      active_run_count: count,
      rejection_count: 0
    }
  end

  describe "initial_state/0" do
    test "returns a fresh state with 0 active runs" do
      state = ProjectRunLimit.initial_state()
      assert state.exists? == false
      assert state.active_run_count == 0
      assert state.rejection_count == 0
    end
  end

  describe "handle_command/2 — run_limit.reserve" do
    test "emits RunLimitReserved with incremented count" do
      state = ProjectRunLimit.initial_state()

      assert {:ok, event_spec} =
               ProjectRunLimit.handle_command(state, %{
                 type: "run_limit.reserve",
                 payload: %{project_id: "proj-1"}
               })

      assert event_spec.stream_id == "project_run_limit:proj-1"
      assert event_spec.event_type == "RunLimitReserved"
      assert event_spec.payload.project_id == "proj-1"
      assert event_spec.payload.active_run_count_after == 1
    end

    test "rejects when project_id is missing" do
      state = ProjectRunLimit.initial_state()

      assert {:error, {:missing_or_invalid, :project_id}} =
               ProjectRunLimit.handle_command(state, %{
                 type: "run_limit.reserve",
                 payload: %{}
               })
    end

    test "rejects with :run_limit_exceeded when at the ceiling" do
      state = limit_state(ProjectRunLimit.max_concurrent_runs())

      assert {:error, :run_limit_exceeded} =
               ProjectRunLimit.handle_command(state, %{
                 type: "run_limit.reserve",
                 payload: %{project_id: "proj-saturated"}
               })
    end
  end

  describe "handle_command/2 — run_limit.release" do
    test "emits RunLimitReleased with decremented count" do
      state = limit_state(5)

      assert {:ok, event_spec} =
               ProjectRunLimit.handle_command(state, %{
                 type: "run_limit.release",
                 payload: %{project_id: "proj-2"}
               })

      assert event_spec.event_type == "RunLimitReleased"
      assert event_spec.payload.active_run_count_after == 4
    end

    test "clamps at zero" do
      state = ProjectRunLimit.initial_state()

      assert {:ok, event_spec} =
               ProjectRunLimit.handle_command(state, %{
                 type: "run_limit.release",
                 payload: %{project_id: "proj-3"}
               })

      assert event_spec.payload.active_run_count_after == 0
    end
  end

  describe "handle_command/2 — unknown" do
    test "returns :unhandled for unknown commands" do
      state = ProjectRunLimit.initial_state()
      assert :unhandled = ProjectRunLimit.handle_command(state, %{type: "x", payload: %{}})
    end
  end

  describe "apply_event/2" do
    test "folds RunLimitReserved" do
      state =
        ProjectRunLimit.apply_event(
          ProjectRunLimit.initial_state(),
          %{
            event_type: "RunLimitReserved",
            payload: %{project_id: "proj-4", active_run_count_after: 1}
          }
        )

      assert state.exists? == true
      assert state.project_id == "proj-4"
      assert state.active_run_count == 1
    end

    test "folds RunLimitReleased with clamp" do
      state =
        ProjectRunLimit.apply_event(
          ProjectRunLimit.initial_state(),
          %{
            event_type: "RunLimitReleased",
            payload: %{project_id: "proj-5", active_run_count_after: -1}
          }
        )

      assert state.active_run_count == 0
    end

    test "folds ProjectRunLimitRejected audit events" do
      state =
        ProjectRunLimit.apply_event(
          ProjectRunLimit.initial_state(),
          %{
            event_type: "ProjectRunLimitRejected",
            payload: %{project_id: "proj-6"}
          }
        )

      assert state.rejection_count == 1
    end

    test "ignores unknown events" do
      state =
        ProjectRunLimit.apply_event(
          ProjectRunLimit.initial_state(),
          %{event_type: "Unknown", payload: %{}}
        )

      assert state.exists? == false
    end
  end

  describe "stream_id/1 and max_concurrent_runs/0" do
    test "builds deterministic stream id" do
      assert ProjectRunLimit.stream_id("p1") == "project_run_limit:p1"
    end

    test "exposes the configured ceiling" do
      assert ProjectRunLimit.max_concurrent_runs() == 100
    end
  end

  describe "has_capacity?/1" do
    test "true when below ceiling" do
      assert ProjectRunLimit.has_capacity?(limit_state(99))
    end

    test "false at ceiling" do
      refute ProjectRunLimit.has_capacity?(limit_state(100))
    end
  end
end

defmodule ForemanServer.StreamGapDetectorTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.StreamGapDetector

  defp flagged_state do
    %StreamGapDetector.State{
      exists?: true,
      stream_id: "x",
      status: "gap_detected",
      detected_at_ms: nil,
      expected_version: nil,
      projected_version: nil,
      resolved_at_ms: nil
    }
  end

  defp ok_state do
    %StreamGapDetector.State{
      exists?: true,
      stream_id: "x",
      status: "ok",
      detected_at_ms: nil,
      expected_version: nil,
      projected_version: nil,
      resolved_at_ms: nil
    }
  end

  describe "initial_state/0" do
    test "returns ok status" do
      state = StreamGapDetector.initial_state()
      assert state.status == "ok"
      assert state.exists? == false
    end
  end

  describe "handle_command/2 — stream_gap.report" do
    test "emits StreamGapDetected on first report" do
      state = StreamGapDetector.initial_state()

      assert {:ok, event_spec} =
               StreamGapDetector.handle_command(state, %{
                 type: "stream_gap.report",
                 payload: %{
                   stream_id: "run:r-1",
                   expected_version: 5,
                   projected_version: 3
                 }
               })

      assert event_spec.stream_id == "stream_gap:run:r-1"
      assert event_spec.event_type == "StreamGapDetected"
      assert event_spec.payload.expected_version == 5
      assert event_spec.payload.projected_version == 3
    end

    test "is idempotent for already-flagged streams" do
      state = flagged_state()

      assert {:ok, :already_flagged} =
               StreamGapDetector.handle_command(state, %{
                 type: "stream_gap.report",
                 payload: %{stream_id: "run:r-2", expected_version: 6, projected_version: 3}
               })
    end

    test "rejects when stream_id is missing" do
      state = StreamGapDetector.initial_state()

      assert {:error, {:missing_or_invalid, :stream_id}} =
               StreamGapDetector.handle_command(state, %{
                 type: "stream_gap.report",
                 payload: %{expected_version: 1}
               })
    end
  end

  describe "handle_command/2 — stream_gap.resolve" do
    test "emits StreamGapResolved when flagged" do
      state = flagged_state()

      assert {:ok, event_spec} =
               StreamGapDetector.handle_command(state, %{
                 type: "stream_gap.resolve",
                 payload: %{stream_id: "run:r-3"}
               })

      assert event_spec.event_type == "StreamGapResolved"
    end

    test "is a no-op when already ok" do
      state = StreamGapDetector.initial_state()

      assert {:ok, :already_ok} =
               StreamGapDetector.handle_command(state, %{
                 type: "stream_gap.resolve",
                 payload: %{stream_id: "run:r-4"}
               })
    end
  end

  describe "handle_command/2 — unknown" do
    test "returns :unhandled" do
      assert :unhandled =
               StreamGapDetector.handle_command(StreamGapDetector.initial_state(), %{
                 type: "x",
                 payload: %{}
               })
    end
  end

  describe "apply_event/2" do
    test "StreamGapDetected flips status" do
      state =
        StreamGapDetector.apply_event(
          StreamGapDetector.initial_state(),
          %{
            event_type: "StreamGapDetected",
            payload: %{stream_id: "run:r-5", detected_at_ms: 500, expected_version: 4}
          }
        )

      assert state.status == "gap_detected"
      assert state.expected_version == 4
      assert state.detected_at_ms == 500
    end

    test "StreamGapResolved resets status" do
      state =
        StreamGapDetector.apply_event(flagged_state(), %{
          event_type: "StreamGapResolved",
          payload: %{stream_id: "run:r-6", resolved_at_ms: 999}
        })

      assert state.status == "ok"
      assert state.resolved_at_ms == 999
    end
  end

  describe "flagged?/1" do
    test "true when gap_detected" do
      assert StreamGapDetector.flagged?(flagged_state())
    end

    test "false when ok" do
      refute StreamGapDetector.flagged?(ok_state())
    end
  end
end

defmodule ForemanServer.Aggregates.RunSlotsIndependentQueuesTest do
  # TRD-006-TEST, AC-001-3: per-project queues advance independently.
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.RunSlots
  alias ForemanServer.Events.{RunSlotAcquired, RunSlotTransferred}

  defp run(state, type, project, payload) do
    {:ok, event} =
      RunSlots.handle_command(state, %{
        type: type,
        payload: Map.put(payload, :project_id, project)
      })

    {event, if(event, do: RunSlots.apply_event(state, event), else: state)}
  end

  defp full_queue(project, cap) do
    holders = for i <- 1..cap, do: "#{project}-h#{i}"
    state =
      Enum.reduce(holders, RunSlots.initial_state(), fn id, st ->
        {_, st} = run(st, "run_slots.acquire", project, %{run_id: id, capacity: cap})
        st
      end)

    {_, state} = run(state, "run_slots.acquire", project, %{run_id: "#{project}-w1", capacity: cap})
    {_, state} = run(state, "run_slots.acquire", project, %{run_id: "#{project}-w2", capacity: cap})
    state
  end

  test "A and B at their limits: an A run finishing advances only A's queue" do
    a = full_queue("a", 2)
    b = full_queue("b", 3)

    assert length(a.waiters) == 2 and length(b.waiters) == 2

    {event, a2} = run(a, "run_slots.release", "a", %{run_id: "a-h1", capacity: 2})

    assert %RunSlotTransferred{released_run_id: "a-h1", acquired_run_id: "a-w1"} = event
    assert Enum.map(a2.waiters, & &1.run_id) == ["a-w2"]
    assert Map.has_key?(a2.holders, "a-w1")

    # B has its own stream and state: nothing in it moved.
    assert b.waiters |> Enum.map(& &1.run_id) == ["b-w1", "b-w2"]
    assert RunSlots.stream_id("a") != RunSlots.stream_id("b")
  end

  test "drop_project_commands/2 targets exactly the waiters, in order, on the project stream" do
    state = full_queue("a", 2)

    cmds = RunSlots.drop_project_commands(state, "a")

    assert Enum.map(cmds, & &1.payload.run_id) == ["a-w1", "a-w2"]
    assert Enum.all?(cmds, &(&1.type == "run_slots.remove_waiter"))
    assert Enum.all?(cmds, &(&1.aggregate_id == "run_slots:a"))
    assert RunSlots.drop_project_commands(RunSlots.initial_state(), "a") == []
  end

  test "applying the drop commands removes every waiter and touches no holder" do
    state = full_queue("a", 2)
    holders_before = Map.keys(state.holders) |> Enum.sort()

    dropped =
      Enum.reduce(RunSlots.drop_project_commands(state, "a"), state, fn cmd, st ->
        {:ok, event} = RunSlots.handle_command(st, cmd)
        RunSlots.apply_event(st, event)
      end)

    assert dropped.waiters == []
    assert Map.keys(dropped.holders) |> Enum.sort() == holders_before
    refute match?(%RunSlotAcquired{}, hd(RunSlots.drop_project_commands(state, "a")))
  end
end

defmodule ForemanServer.Aggregates.RunSlotsDropProjectTest do
  # TRD-006-TEST: `drop_project/1` against the real event store. Groundwork
  # only; it does not validate AC-017-2.
  use ExUnit.Case, async: false

  alias ForemanServer.{Aggregate, CommandGateway}
  alias ForemanServer.Aggregates.RunSlots

  setup_all do
    {:ok, _} = Application.ensure_all_started(:eventstore)
    :ok
  end

  setup do
    ForemanServer.TestSupport.RunSlotsReset.reset!()
    on_exit(fn -> ForemanServer.TestSupport.RunSlotsReset.reset!() end)
    :ok
  end

  defp acquire(project, run_id, cap) do
    {:ok, _} =
      CommandGateway.dispatch_system(
        %{
          type: "run_slots.acquire",
          command_id: "drop-test:#{project}:#{run_id}",
          aggregate_id: RunSlots.stream_id(project),
          payload: %{run_id: run_id, capacity: cap, project_id: project}
        },
        5_000
      )
  end

  defp state(project), do: elem(Aggregate.load(RunSlots, RunSlots.stream_id(project)), 0)

  test "removes the waiters of the project and leaves its holders" do
    project = "drop-a-#{System.unique_integer([:positive])}"
    for id <- ~w(h1 h2), do: acquire(project, id, 2)
    for id <- ~w(w1 w2 w3), do: acquire(project, id, 2)
    assert length(state(project).waiters) == 3

    assert {:ok, ["w1", "w2", "w3"]} = RunSlots.drop_project(project)

    after_drop = state(project)
    assert after_drop.waiters == []
    assert Map.keys(after_drop.holders) |> Enum.sort() == ["h1", "h2"]
  end

  test "does not touch another project's queue, and is idempotent" do
    a = "drop-a-#{System.unique_integer([:positive])}"
    b = "drop-b-#{System.unique_integer([:positive])}"
    acquire(a, "h1", 1)
    acquire(a, "w1", 1)
    acquire(b, "h1", 1)
    acquire(b, "w1", 1)

    assert {:ok, ["w1"]} = RunSlots.drop_project(a)
    assert {:ok, []} = RunSlots.drop_project(a)
    assert Enum.map(state(b).waiters, & &1.run_id) == ["w1"]
  end
end
