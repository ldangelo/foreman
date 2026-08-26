defmodule ForemanServerWeb.DebugDashboardLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  test "dashboard renders without crashing" do
    html =
      rendered_to_string(
        ForemanServerWeb.DebugDashboardLive.render(%{
          section: nil,
          page_title: "Debug dashboard",
          runs: [],
          phases: [],
          workers: []
        })
      )

    assert html =~ "Debug dashboard"
    assert html =~ "No run actors are currently loaded."
  end

  test "section filtering renders only the chosen section" do
    runs_html =
      rendered_to_string(
        ForemanServerWeb.DebugDashboardLive.render(%{
          section: :runs,
          page_title: "Debug · Runs",
          runs: [],
          phases: [],
          workers: []
        })
      )

    assert runs_html =~ "Debug · Runs"
    assert runs_html =~ "No run actors are currently loaded."
    refute runs_html =~ "<h2>Phases</h2>"
    refute runs_html =~ "<h2>Workers</h2>"
  end

  test "Presence.update surfaces a presence_diff within 1 second of subscribe" do
    aggregate_id = "presence-update-test-#{System.unique_integer([:positive])}"

    ForemanServerWeb.Presence.track(self(), "debug:aggregates", aggregate_id, %{version: 1})
    Phoenix.PubSub.subscribe(ForemanServer.PubSub, "debug:aggregates")

    ForemanServerWeb.Presence.update(self(), "debug:aggregates", aggregate_id, fn _meta ->
      %{version: 2}
    end)

    receive do
      %Phoenix.Socket.Broadcast{event: "presence_diff"} = _ -> :ok
    after
      1000 ->
        flunk("presence_diff not delivered within 1 second")
    end

    %{^aggregate_id => %{metas: [%{version: 2}]}} =
      ForemanServerWeb.Presence.list("debug:aggregates")
  end

  test "run, phase, and worker pages render state snapshots" do
    run_html =
      rendered_to_string(
        ForemanServerWeb.RunDebugLive.render(%{
          run_id: "run-123",
          snapshot: %{
            pid: self(),
            state: %{run_id: "run-123", status: "in_progress", task_id: "task-1"}
          }
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
          snapshot: %{
            pid: self(),
            state: %{status: "running", tool_events: 3, assistant_messages: 4}
          }
        })
      )

    assert worker_html =~ "Worker debug: worker-1"
    assert worker_html =~ "Tool events: 3"
  end
end
