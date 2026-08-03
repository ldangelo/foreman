defmodule ForemanServerWeb.DebugDashboardLiveTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  test "dashboard renders without crashing" do
    html =
      rendered_to_string(
        ForemanServerWeb.DebugDashboardLive.render(%{runs: [], phases: [], workers: []})
      )

    assert html =~ "Debug dashboard"
    assert html =~ "No run actors are currently loaded."
  end

  test "run, phase, and worker pages render state snapshots" do
    run_html =
      rendered_to_string(
        ForemanServerWeb.RunDebugLive.render(%{
          run_id: "run-123",
          snapshot: %{pid: self(), state: %{run_id: "run-123", status: "in_progress", task_id: "task-1"}}
        })
      )

    assert run_html =~ "Run debug: run-123"
    assert run_html =~ "Task: task-1"

    phase_html =
      rendered_to_string(
        ForemanServerWeb.PhaseDebugLive.render(%{
          run_id: "run-123",
          phase_id: "phase-1",
          snapshot: %{pid: self(), state: %{status: "completed", attempt: 2}}
        })
      )

    assert phase_html =~ "Phase debug: phase-1"
    assert phase_html =~ "Attempt: 2"

    worker_html =
      rendered_to_string(
        ForemanServerWeb.WorkerDebugLive.render(%{
          run_id: "run-123",
          worker_id: "worker-1",
          snapshot: %{pid: self(), state: %{status: "running", tool_events: 3, assistant_messages: 4}}
        })
      )

    assert worker_html =~ "Worker debug: worker-1"
    assert worker_html =~ "Tool events: 3"
  end
end
