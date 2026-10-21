defmodule ForemanServer.ProjectPauseLimitsProjectionTest do
  # The read model of pause/limits: pause flips status, the limits block shows
  # configured limits and today's usage, and dispatched-but-not-started tasks
  # are listed as deferred so a paused or capped project's backlog is visible.
  use ExUnit.Case, async: false

  alias ForemanServer.{ProjectionStore, ProjectLimits}
  alias ForemanServer.TestSupport.ProjectionStoreReset

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok
  end

  @now ~U[2026-03-04 10:30:00Z]

  defp apply!(events), do: :ok = ProjectionStore.apply_events(events)

  defp register(id, config \\ %{}),
    do: %{
      event_type: "ProjectRegistered",
      payload: %{project_id: id, path: "/tmp/#{id}", config: config}
    }

  defp reserved(id, run_id, day),
    do: %{
      event_type: "ProjectRunReserved",
      payload: %{
        project_id: id,
        run_id: run_id,
        command_id: "c-#{run_id}",
        sequence: 0,
        run_start_payload: %{},
        reserved_on: day
      }
    }

  test "pause and resume flip the projected status; nothing else changes" do
    apply!([register("p1", %{goal: "g"})])
    apply!([%{event_type: "ProjectPaused", payload: %{project_id: "p1"}}])
    assert %{status: "paused", config: %{goal: "g"}} = ProjectionStore.project_projection("p1")

    apply!([%{event_type: "ProjectResumed", payload: %{project_id: "p1"}}])
    assert %{status: "active"} = ProjectionStore.project_projection("p1")
  end

  test "limits block: effective limit, usage today, remaining, cap_reached, reset time" do
    apply!([
      register("p1", %{max_concurrent_runs: 2, daily_thread_cap: 3}),
      reserved("p1", "r1", "2026-03-04"),
      %{
        event_type: "ProjectThreadStarted",
        payload: %{project_id: "p1", thread_kind: "jobsite", thread_id: "js1", day: "2026-03-04"}
      },
      reserved("p1", "r0", "2026-03-03")
    ])

    assert %{
             max_concurrent_runs: 2,
             active_runs: 2,
             daily_thread_cap: 3,
             threads_started_today: 2,
             remaining_today: 1,
             cap_reached?: false,
             resets_at: "2026-03-05T00:00:00Z",
             deferred_tasks: 0
           } = ProjectionStore.project_limits("p1", @now)

    apply!([
      %{
        event_type: "ProjectThreadStarted",
        payload: %{project_id: "p1", thread_kind: "jobsite", thread_id: "js2", day: "2026-03-04"}
      }
    ])

    assert %{cap_reached?: true, remaining_today: 0} = ProjectionStore.project_limits("p1", @now)
  end

  test "the effective run limit is capped by the global slot gate" do
    previous = Application.get_env(:foreman_server, :max_concurrent_runs)
    Application.put_env(:foreman_server, :max_concurrent_runs, 3)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:foreman_server, :max_concurrent_runs, previous),
        else: Application.delete_env(:foreman_server, :max_concurrent_runs)
    end)

    apply!([register("p1", %{max_concurrent_runs: 50})])
    assert %{max_concurrent_runs: 3} = ProjectionStore.project_limits("p1", @now)
  end

  test "a replayed thread is counted once and only 8 days are retained" do
    events =
      for n <- 1..10 do
        day = Date.new!(2026, 3, n) |> Date.to_iso8601()
        reserved("p1", "r#{n}", day)
      end

    apply!([register("p1") | events] ++ [hd(events)])

    assert ProjectionStore.threads_started_on("p1", "2026-03-10") == 1
    assert ProjectionStore.threads_started_on("p1", "2026-03-03") == 1
    assert ProjectionStore.threads_started_on("p1", "2026-03-02") == 0
  end

  test "dispatched tasks without a started run are deferred; started ones are not" do
    apply!(
      [register("p1")] ++
        task("t1", "p1", "run-1") ++
        task("t2", "p1", "run-2") ++
        [
          %{
            event_type: "RunStarted",
            payload: %{run_id: "run-2", task_id: "t2", project_id: "p1"}
          }
        ]
    )

    assert ProjectionStore.deferred_task_ids("p1") == ["t1"]
    assert %{deferred_tasks: 1} = ProjectionStore.project_limits("p1", @now)
  end

  test "unknown project has no limits" do
    assert ProjectionStore.project_limits("nope", @now) == nil
  end

  test "ProjectLimits.build is pure: no cap means nil remaining and never reached" do
    project = %{config: %{}}

    assert %{daily_thread_cap: nil, remaining_today: nil, cap_reached?: false} =
             ProjectLimits.build(
               project,
               %{
                 active_runs: 0,
                 threads_started_today: 99,
                 deferred_tasks: 0,
                 deferred_by_reason: %{}
               },
               @now
             )
  end

  defp task(task_id, project_id, run_id) do
    [
      %{
        event_type: "TaskCreated",
        payload: %{
          task_id: task_id,
          project_id: project_id,
          title: task_id,
          status: "open",
          task_type: "implement"
        }
      },
      approved(task_id, run_id),
      dispatched(task_id, run_id)
    ]
  end

  defp approved(task_id, run_id),
    do: %{
      event_type: "TaskApproved",
      payload: %{
        task_id: task_id,
        approval_id: "a-#{task_id}",
        approved_by: "t",
        approved_at: "2026-03-04T10:00:00Z",
        run_id: run_id,
        workflow_snapshot: %{}
      }
    }

  defp dispatched(task_id, run_id),
    do: %{
      event_type: "TaskDispatched",
      payload: %{task_id: task_id, run_id: run_id, approval_id: "a-#{task_id}"}
    }
end
