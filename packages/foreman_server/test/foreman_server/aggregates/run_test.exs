defmodule ForemanServer.Aggregates.RunTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.Run

  test "run.start emits RunStarted and apply_event marks the run in progress" do
    run_id = "run-start"

    {:ok, event_spec} =
      Run.handle_command(Run.initial_state(), %{
        type: "run.start",
        payload: %{run_id: run_id, task_id: "task-1"}
      })

    state = Run.apply_event(Run.initial_state(), %{event_type: event_spec.event_type, payload: event_spec.payload})

    assert event_spec.event_type == "RunStarted"
    assert event_spec.stream_id == "run:#{run_id}"
    assert state.run_id == run_id
    assert state.task_id == "task-1"
    assert state.status == "in_progress"
    assert state.terminal? == false
  end

  test "run.complete marks the run completed and terminal" do
    run_id = "run-complete"
    initial_state = Run.initial_state()

    {:ok, start_event} =
      Run.handle_command(initial_state, %{
        type: "run.start",
        payload: %{run_id: run_id, task_id: "task-2"}
      })

    started_state =
      Run.apply_event(initial_state, %{event_type: start_event.event_type, payload: start_event.payload})

    {:ok, complete_event} =
      Run.handle_command(started_state, %{
        type: "run.complete",
        payload: %{run_id: run_id, sequence: 1}
      })

    completed_state =
      Run.apply_event(started_state, %{
        event_type: complete_event.event_type,
        payload: complete_event.payload
      })

    assert complete_event.event_type == "RunCompleted"
    assert completed_state.status == "completed"
    assert completed_state.terminal? == true
    assert completed_state.last_sequence == 1
  end
end
