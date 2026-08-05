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
