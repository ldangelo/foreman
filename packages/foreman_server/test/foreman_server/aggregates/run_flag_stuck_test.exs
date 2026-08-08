defmodule ForemanServer.Aggregates.RunFlagStuckTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.Run

  defp start_run_state(run_id, task_id \\ "task-1") do
    initial_state = Run.initial_state()

    {:ok, start_event} =
      Run.handle_command(initial_state, %{
        type: "run.start",
        payload: %{
          run_id: run_id,
          project_id: "project-1",
          task_id: task_id,
          workflow_snapshot: %{}
        }
      })

    Run.apply_event(initial_state, %{
      event_type: start_event.event_type,
      payload: start_event.payload
    })
  end

  test "run.flag_stuck emits RunFlaggedStuck for an active run" do
    run_id = "run-1"
    state = start_run_state(run_id)

    {:ok, event_spec} =
      Run.handle_command(state, %{
        type: "run.flag_stuck",
        payload: %{run_id: run_id, flagged_at: 1_725_000_000_000}
      })

    assert event_spec.event_type == "RunFlaggedStuck"
    assert event_spec.stream_id == "run:#{run_id}"
    assert event_spec.payload.run_id == run_id
    assert event_spec.payload.project_id == "project-1"
    assert event_spec.payload.flagged_at == 1_725_000_000_000
  end

  test "run.flag_stuck rejects terminal mutation after run.complete" do
    run_id = "run-2"
    started_state = start_run_state(run_id)

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

    assert {:error, {:run_terminal, "completed"}} =
             Run.handle_command(completed_state, %{
               type: "run.flag_stuck",
               payload: %{run_id: run_id}
             })
  end

  test "RunFlaggedStuck marks the run stuck and terminal" do
    state =
      start_run_state("run-3")
      |> Run.apply_event(%{
        event_type: "RunFlaggedStuck",
        payload: %{
          run_id: "run-3",
          project_id: "project-1",
          flagged_at: 1_725_000_060_000
        }
      })

    assert state.status == "stuck"
    assert state.terminal? == true
  end

  test "run.flag_stuck defaults flagged_at to the current unix millisecond" do
    run_id = "run-4"
    state = start_run_state(run_id)
    before_ms = System.system_time(:millisecond)

    {:ok, event_spec} =
      Run.handle_command(state, %{
        type: "run.flag_stuck",
        payload: %{run_id: run_id}
      })

    after_ms = System.system_time(:millisecond)

    assert is_integer(event_spec.payload.flagged_at)
    assert event_spec.payload.flagged_at >= before_ms
    assert event_spec.payload.flagged_at <= after_ms
  end

  test "run.flag_stuck rejects after the run has been flagged stuck" do
    run_id = "run-5"
    started_state = start_run_state(run_id)

    {:ok, flag_event} =
      Run.handle_command(started_state, %{
        type: "run.flag_stuck",
        payload: %{run_id: run_id, flagged_at: 1_725_000_000_000}
      })

    stuck_state =
      Run.apply_event(started_state, %{
        event_type: flag_event.event_type,
        payload: flag_event.payload
      })

    assert {:error, {:run_terminal, "stuck"}} =
             Run.handle_command(stuck_state, %{
               type: "run.flag_stuck",
               payload: %{run_id: run_id}
             })

    assert {:error, {:run_terminal, "stuck"}} =
             Run.handle_command(stuck_state, %{
               type: "run.update",
               payload: %{run_id: run_id, status: "completed"}
             })
  end
end
