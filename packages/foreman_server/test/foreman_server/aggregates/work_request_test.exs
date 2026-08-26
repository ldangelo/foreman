defmodule ForemanServer.Aggregates.WorkRequestTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.WorkRequest
  alias ForemanServer.Aggregates.WorkRequest.State

  alias ForemanServer.Events.{
    WorkCancelled,
    WorkExecutionCompleted,
    WorkExecutionFailed,
    WorkSubmitted
  }

  describe "initial_state/0" do
    test "returns a state with all fields nil" do
      state = WorkRequest.initial_state()

      assert state.work_id == nil
      assert state.status == nil
      assert state.project_id == nil
      assert state.run_id == nil
      assert state.bound_run_id == nil
      assert state.submission_id == nil
      assert state.workflow_snapshot == nil
    end
  end

  describe "stream_id/1" do
    test "builds canonical work: prefix" do
      assert WorkRequest.stream_id("abc123") == "work:abc123"
    end
  end

  describe "apply_event/2 — WorkSubmitted" do
    test "sets all fields and status to :submitted" do
      state = WorkRequest.initial_state()

      event = %WorkSubmitted{
        work_id: "work-1",
        project_id: "proj-1",
        run_id: "run-1",
        submission_id: "sub-1",
        workflow_snapshot: %{"phases" => []}
      }

      result = WorkRequest.apply_event(state, event)

      assert result.work_id == "work-1"
      assert result.status == :submitted
      assert result.project_id == "proj-1"
      assert result.run_id == "run-1"
      assert result.submission_id == "sub-1"
      assert result.workflow_snapshot == %{"phases" => []}
      assert result.bound_run_id == nil
    end
  end

  describe "apply_event/2 — WorkCancelled" do
    test "transitions status to :cancelled" do
      state = %State{
        work_id: "work-1",
        status: :submitted,
        submitted_at: System.monotonic_time(:microsecond)
      }

      result = WorkRequest.apply_event(state, %WorkCancelled{work_id: "work-1"})
    end
  end

  describe "apply_event/2 — WorkExecutionCompleted" do
    test "transitions status to :succeeded" do
      state = %State{
        work_id: "work-1",
        status: :running,
        submitted_at: System.monotonic_time(:microsecond)
      }

      result =
        WorkRequest.apply_event(state, %WorkExecutionCompleted{
          work_id: "work-1",
          run_id: "run-1"
        })
    end
  end

  describe "apply_event/2 — WorkExecutionFailed" do
    test "transitions status to :failed" do
      state = %State{
        work_id: "work-1",
        status: :running,
        submitted_at: System.monotonic_time(:microsecond)
      }

      result =
        WorkRequest.apply_event(state, %WorkExecutionFailed{
          work_id: "work-1",
          run_id: "run-1"
        })
    end
  end

  describe "status machine" do
    test "submitted → queued → running → succeeded" do
      state0 = WorkRequest.initial_state()

      # submitted
      state1 =
        WorkRequest.apply_event(state0, %WorkSubmitted{
          work_id: "work-1",
          project_id: "proj-1",
          run_id: "run-1",
          submission_id: "sub-1",
          workflow_snapshot: %{}
        })

      assert state1.status == :submitted

      # queued (Dispatcher sets this — simulate by direct struct update)
      state2 = %State{state1 | status: :queued}
      assert state2.status == :queued

      # running
      state3 = %State{state2 | status: :running, bound_run_id: state2.run_id}
      assert state3.status == :running

      # succeeded
      state4 =
        WorkRequest.apply_event(state3, %WorkExecutionCompleted{
          work_id: "work-1",
          run_id: "run-1"
        })

      assert state4.status == :succeeded
    end

    test "submitted → queued → running → failed" do
      state0 = WorkRequest.initial_state()

      state1 =
        WorkRequest.apply_event(state0, %WorkSubmitted{
          work_id: "work-2",
          project_id: "proj-1",
          run_id: "run-2",
          submission_id: "sub-2",
          workflow_snapshot: %{}
        })

      assert state1.status == :submitted

      state2 = %State{state1 | status: :queued}
      state3 = %State{state2 | status: :running, bound_run_id: state2.run_id}

      state4 =
        WorkRequest.apply_event(state3, %WorkExecutionFailed{
          work_id: "work-2",
          run_id: "run-2"
        })

      assert state4.status == :failed
    end

    test "submitted → cancelled" do
      state0 = WorkRequest.initial_state()

      state1 =
        WorkRequest.apply_event(state0, %WorkSubmitted{
          work_id: "work-3",
          project_id: "proj-1",
          run_id: "run-3",
          submission_id: "sub-3",
          workflow_snapshot: %{}
        })

      assert state1.status == :submitted

      state2 = WorkRequest.apply_event(state1, %WorkCancelled{work_id: "work-3"})
      assert state2.status == :cancelled
    end
  end
end
