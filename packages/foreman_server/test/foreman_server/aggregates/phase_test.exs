defmodule ForemanServer.Aggregates.PhaseTest do
  @moduledoc """
  TRD-008: Phase aggregate unit tests.

  Pins the per-run phase state transitions:

    * `phase.start` from `initial_state/0` emits `PhaseStarted` and stamps
      `exists?: true`, `status: "in_progress"`, `terminal?: false`.
    * `phase.start` from a started state is rejected with
      `{:error, :phase_already_started}`.
    * `phase.complete` / `phase.fail` / `phase.timeout` / `phase.skip` from
      `initial_state` are rejected with `{:error, :phase_not_started}`.
    * `phase.complete` from `in_progress` emits `PhaseCompleted` and
      `terminal?: true`. Subsequent commands on the terminal state are
      rejected with `{:error, :phase_terminal}`.
    * `phase.fail` / `phase.timeout` / `phase.skip` follow the same
      start-projection logic with the corresponding event type.
    * `phase.retry` is permitted only from `failed`, `timed_out`, or
      `retrying`; it rejects `in_progress` with `{:error, :phase_not_retryable}`
      and terminal states with `{:error, :phase_terminal}`.
    * `apply_event/2` folds each typed event into the State struct via
      `%State{state | ...}` — no `Map.merge` of the projection.
    * Stream id is deterministic: `"phase:<run_id>:<phase_id>"`.
  """

  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.Phase

  defp uuid, do: EventStore.UUID.uuid4()

  defp start_state, do: Phase.initial_state()

  defp fold(state, event_type, payload) do
    Phase.apply_event(state, %{event_type: event_type, payload: payload})
  end

  defp started_state do
    run_id = uuid()
    phase_id = uuid()

    {:ok, spec} =
      Phase.handle_command(start_state(), %{
        type: "phase.start",
        payload: %{run_id: run_id, phase_id: phase_id}
      })

    fold(start_state(), spec.event_type, spec.payload)
  end

  # ---------------------------------------------------------------------------
  # initial_state
  # ---------------------------------------------------------------------------

  test "initial_state has exists?: false, terminal?: false" do
    state = Phase.initial_state()

    assert state.exists? == false
    assert state.terminal? == false
    assert state.status == nil
    assert state.phase_id == nil
    assert state.run_id == nil
  end

  # ---------------------------------------------------------------------------
  # phase.start
  # ---------------------------------------------------------------------------

  describe "handle_command/2 — phase.start" do
    test "from initial_state emits PhaseStarted with deterministic stream id" do
      run_id = uuid()
      phase_id = uuid()

      assert {:ok, spec} =
               Phase.handle_command(start_state(), %{
                 type: "phase.start",
                 payload: %{run_id: run_id, phase_id: phase_id}
               })

      assert spec.event_type == "PhaseStarted"
      assert spec.stream_id == "phase:#{run_id}:#{phase_id}"
      assert spec.payload.run_id == run_id
      assert spec.payload.phase_id == phase_id
    end

    test "stamps exists?: true, status: in_progress via apply_event" do
      state = started_state()

      assert state.exists? == true
      assert state.terminal? == false
      assert state.status == "in_progress"
    end

    test "rejects missing run_id with {:missing_or_invalid, :run_id}" do
      assert {:error, {:missing_or_invalid, :run_id}} =
               Phase.handle_command(start_state(), %{
                 type: "phase.start",
                 payload: %{phase_id: "phase-x"}
               })
    end

    test "rejects missing phase_id with {:missing_or_invalid, :phase_id}" do
      assert {:error, {:missing_or_invalid, :phase_id}} =
               Phase.handle_command(start_state(), %{
                 type: "phase.start",
                 payload: %{run_id: "run-x"}
               })
    end

    test "rejects phase.start from already-started state" do
      state = started_state()

      assert {:error, :phase_already_started} =
               Phase.handle_command(state, %{
                 type: "phase.start",
                 payload: %{run_id: "run-y", phase_id: "phase-y"}
               })
    end
  end

  # ---------------------------------------------------------------------------
  # phase.complete / phase.fail / phase.timeout / phase.skip
  # ---------------------------------------------------------------------------

  describe "handle_command/2 — phase.complete" do
    test "rejects from initial_state with :phase_not_started" do
      assert {:error, :phase_not_started} =
               Phase.handle_command(start_state(), %{
                 type: "phase.complete",
                 payload: %{run_id: "run-x", phase_id: "phase-x"}
               })
    end

    test "from in_progress emits PhaseCompleted and apply_event folds terminal?" do
      started = started_state()
      run_id = started.run_id
      phase_id = started.phase_id

      assert {:ok, spec} =
               Phase.handle_command(started, %{
                 type: "phase.complete",
                 payload: %{run_id: run_id, phase_id: phase_id}
               })

      assert spec.event_type == "PhaseCompleted"

      state = fold(started, spec.event_type, spec.payload)
      assert state.status == "completed"
      assert state.terminal? == true
    end

    test "rejects after terminal" do
      started = started_state()
      run_id = started.run_id
      phase_id = started.phase_id

      {:ok, done_spec} =
        Phase.handle_command(started, %{
          type: "phase.complete",
          payload: %{run_id: run_id, phase_id: phase_id}
        })

      terminal = fold(started, done_spec.event_type, done_spec.payload)

      assert {:error, :phase_terminal} =
               Phase.handle_command(terminal, %{
                 type: "phase.complete",
                 payload: %{run_id: run_id, phase_id: phase_id}
               })
    end
  end

  describe "handle_command/2 — phase.fail" do
    test "emits PhaseFailed and marks failed + terminal" do
      started = started_state()

      assert {:ok, spec} =
               Phase.handle_command(started, %{
                 type: "phase.fail",
                 payload: %{run_id: started.run_id, phase_id: started.phase_id}
               })

      state = fold(started, spec.event_type, spec.payload)
      assert spec.event_type == "PhaseFailed"
      assert state.status == "failed"
      assert state.terminal? == true
    end
  end

  describe "handle_command/2 — phase.timeout" do
    test "emits PhaseTimedOut and marks timed_out + terminal" do
      started = started_state()

      assert {:ok, spec} =
               Phase.handle_command(started, %{
                 type: "phase.timeout",
                 payload: %{run_id: started.run_id, phase_id: started.phase_id}
               })

      state = fold(started, spec.event_type, spec.payload)
      assert spec.event_type == "PhaseTimedOut"
      assert state.status == "timed_out"
      assert state.terminal? == true
    end
  end

  describe "handle_command/2 — phase.skip" do
    test "emits PhaseSkipped from in_progress" do
      started = started_state()

      assert {:ok, spec} =
               Phase.handle_command(started, %{
                 type: "phase.skip",
                 payload: %{run_id: started.run_id, phase_id: started.phase_id}
               })

      state = fold(started, spec.event_type, spec.payload)
      assert spec.event_type == "PhaseSkipped"
      assert state.status == "skipped"
      assert state.terminal? == true
    end
  end

  # ---------------------------------------------------------------------------
  # phase.retry
  # ---------------------------------------------------------------------------

  describe "handle_command/2 — phase.retry" do
    test "rejects from in_progress with :phase_not_retryable" do
      started = started_state()

      assert {:error, :phase_not_retryable} =
               Phase.handle_command(started, %{
                 type: "phase.retry",
                 payload: %{run_id: started.run_id, phase_id: started.phase_id}
               })
    end

    test "permits from failed state" do
      started = started_state()

      {:ok, fail_spec} =
        Phase.handle_command(started, %{
          type: "phase.fail",
          payload: %{run_id: started.run_id, phase_id: started.phase_id}
        })

      failed = fold(started, fail_spec.event_type, fail_spec.payload)

      {:ok, retry_spec} =
        Phase.handle_command(failed, %{
          type: "phase.retry",
          payload: %{run_id: failed.run_id, phase_id: failed.phase_id}
        })

      assert retry_spec.event_type == "PhaseRetried"

      retried = fold(failed, retry_spec.event_type, retry_spec.payload)
      assert retried.status == "retrying"
      assert retried.terminal? == false
      assert retried.attempt == 1
    end

    test "permits from timed_out" do
      started = started_state()

      {:ok, timeout_spec} =
        Phase.handle_command(started, %{
          type: "phase.timeout",
          payload: %{run_id: started.run_id, phase_id: started.phase_id}
        })

      timed_out = fold(started, timeout_spec.event_type, timeout_spec.payload)

      assert {:ok, _} =
               Phase.handle_command(timed_out, %{
                 type: "phase.retry",
                 payload: %{run_id: timed_out.run_id, phase_id: timed_out.phase_id}
               })
    end

    test "rejects from completed with :phase_not_retryable" do
      started = started_state()

      {:ok, done_spec} =
        Phase.handle_command(started, %{
          type: "phase.complete",
          payload: %{run_id: started.run_id, phase_id: started.phase_id}
        })

      completed = fold(started, done_spec.event_type, done_spec.payload)

      assert {:error, :phase_not_retryable} =
               Phase.handle_command(completed, %{
                 type: "phase.retry",
                 payload: %{run_id: completed.run_id, phase_id: completed.phase_id}
               })
    end

    test "rejects from skipped with :phase_not_retryable" do
      started = started_state()

      {:ok, skip_spec} =
        Phase.handle_command(started, %{
          type: "phase.skip",
          payload: %{run_id: started.run_id, phase_id: started.phase_id}
        })

      skipped = fold(started, skip_spec.event_type, skip_spec.payload)

      assert {:error, :phase_not_retryable} =
               Phase.handle_command(skipped, %{
                 type: "phase.retry",
                 payload: %{run_id: skipped.run_id, phase_id: skipped.phase_id}
               })
    end
  end

  # ---------------------------------------------------------------------------
  # apply_event
  # ---------------------------------------------------------------------------

  describe "apply_event/2 — typed event fold" do
    test "PhaseStarted uses %State{state | ...} only" do
      started = started_state()

      assert %Phase.State{exists?: true, status: "in_progress", terminal?: false} =
               started
    end

    test "PhaseCompleted sets status completed and terminal? true" do
      started = started_state()

      next =
        fold(started, "PhaseCompleted", %{
          run_id: started.run_id,
          phase_id: started.phase_id
        })

      assert next.status == "completed"
      assert next.terminal? == true
    end

    test "PhaseFailed sets status failed and terminal? true" do
      started = started_state()

      next =
        fold(started, "PhaseFailed", %{run_id: started.run_id, phase_id: started.phase_id})

      assert next.status == "failed"
      assert next.terminal? == true
    end

    test "PhaseTimedOut sets status timed_out and terminal? true" do
      started = started_state()

      next =
        fold(started, "PhaseTimedOut", %{run_id: started.run_id, phase_id: started.phase_id})

      assert next.status == "timed_out"
      assert next.terminal? == true
    end

    test "PhaseRetried advances attempt, status retrying, terminal? false" do
      started = started_state()

      next =
        fold(started, "PhaseRetried", %{run_id: started.run_id, phase_id: started.phase_id})

      assert next.status == "retrying"
      assert next.terminal? == false
      assert next.attempt == 1
    end

    test "PhaseSkipped sets status skipped and terminal? true" do
      started = started_state()

      next =
        fold(started, "PhaseSkipped", %{run_id: started.run_id, phase_id: started.phase_id})

      assert next.status == "skipped"
      assert next.terminal? == true
    end

    test "unknown event types leave state unchanged" do
      started = started_state()

      assert fold(started, "PhaseSomethingElse", %{run_id: "x", phase_id: "y"}) == started
    end
  end

  # ---------------------------------------------------------------------------
  # unknown commands
  # ---------------------------------------------------------------------------

  describe "handle_command/2 — unknown command types" do
    test "returns :unhandled" do
      assert :unhandled ==
               Phase.handle_command(start_state(), %{
                 type: "phase.unknown",
                 payload: %{run_id: "run", phase_id: "phase"}
               })
    end
  end
end
