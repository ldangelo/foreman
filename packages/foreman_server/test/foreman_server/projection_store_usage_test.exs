defmodule ForemanServer.ProjectionStoreUsageTest do
  @moduledoc """
  The usage read model (`ProjectionStore.usage/2`): attribution to the project,
  thread kind and role, jobsite and review usage folded once, replay equality.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)

    :ok =
      ProjectionStore.apply_events([
        %{event_type: "ProjectRegistered", payload: %{project_id: "proj", path: "/tmp/proj"}}
      ])

    :ok
  end

  defp usage_event(run_id, worker, extra) do
    %{
      event_type: "UsageRecorded",
      payload:
        Map.merge(
          %{
            run_id: run_id,
            worker_id: worker,
            provider: "claude",
            project_id: "proj",
            model: "m1",
            input_tokens: 10,
            output_tokens: 5,
            total_tokens: 15,
            cost_usd: 0.01,
            at: "2026-01-01T10:00:00Z"
          },
          extra
        )
    }
  end

  defp jobsite_events(id, agent) do
    [
      %{
        event_type: "JobsiteStarted",
        payload: %{
          jobsite_id: id,
          repo_path: "/tmp/proj",
          strategy: "worktree",
          project_id: "proj",
          agent: agent
        }
      }
    ]
  end

  defp iteration(id, index, usage) do
    %{
      event_type: "JobsiteIterationCompleted",
      payload: %{jobsite_id: id, index: index, status: "completed", usage: usage}
    }
  end

  test "unknown project is nil; known project without usage is empty" do
    assert ProjectionStore.usage("nope") == nil
    assert %{total: %{events: 0, usage: %{cost_usd: nil}}} = ProjectionStore.usage("proj")
  end

  test "workflow usage rolls up by thread, model, provider and role" do
    :ok =
      ProjectionStore.apply_events([
        usage_event("run-1", "w1", %{}),
        usage_event("run-1", "w2", %{model: nil, cost_usd: nil}),
        usage_event("run-2", "w1", %{role: "coordinator"})
      ])

    usage = ProjectionStore.usage("proj")
    assert usage.total.events == 3
    assert usage.total.cost_unknown_events == 1
    assert usage.by_thread["run-1"].bucket.events == 2
    assert Map.keys(usage.by_model) |> Enum.sort() == ["m1", "unknown"]
    assert Map.keys(usage.by_role) |> Enum.sort() == ["coordinator", "thread"]

    run_total =
      usage.by_thread |> Map.values() |> Enum.map(& &1.bucket.usage.total_tokens) |> Enum.sum()

    assert run_total == usage.total.usage.total_tokens
  end

  test "event without project id is attributed through the run projection" do
    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "RunStarted",
          payload: %{run_id: "run-h", task_id: "t", project_id: "proj"}
        },
        usage_event("run-h", "w1", %{project_id: nil})
      ])

    assert ProjectionStore.usage("proj").total.events == 1
  end

  test "malformed usage payload is ignored without raising" do
    :ok =
      ProjectionStore.apply_events([
        %{event_type: "UsageRecorded", payload: %{run_id: 5, worker_id: nil}}
      ])

    assert ProjectionStore.usage("proj").total.events == 0
  end

  test "jobsite iteration usage reaches the rollup with the jobsite model and kind" do
    :ok =
      ProjectionStore.apply_events(
        jobsite_events("js-1", %{"provider" => "claude", "model" => "m1"}) ++
          [
            iteration("js-1", 1, %{"input_tokens" => 100, "output_tokens" => 20}),
            iteration("js-1", 2, %{"input_tokens" => 50, "output_tokens" => 5}),
            iteration("js-1", 3, %{})
          ]
      )

    usage = ProjectionStore.usage("proj")
    assert %{thread_kind: "jobsite", bucket: %{events: 2}} = usage.by_thread["js-1"]
    assert usage.by_thread["js-1"].bucket.usage.input_tokens == 150
    assert Map.keys(usage.by_model) == ["m1"]
    assert usage.total.cost_unknown_events == 2
    assert usage.total.usage.cost_usd == nil
  end

  test "a jobsite reporting through UsageRecorded is not double counted with its iterations" do
    for order <- [:iteration_first, :worker_first] do
      ProjectionStoreReset.reset!()

      :ok =
        ProjectionStore.apply_events([
          %{event_type: "ProjectRegistered", payload: %{project_id: "proj", path: "/tmp/proj"}}
        ])

      events =
        jobsite_events("js-2", %{"provider" => "claude", "model" => "m1"}) ++
          if order == :iteration_first do
            [iteration("js-2", 1, %{"input_tokens" => 15}), usage_event("js-2", "w1", %{})]
          else
            [usage_event("js-2", "w1", %{}), iteration("js-2", 1, %{"input_tokens" => 15})]
          end

      :ok = ProjectionStore.apply_events(events)
      usage = ProjectionStore.usage("proj")
      assert usage.total.events == 1, "order #{order}"
      assert usage.total.usage.total_tokens == 15
    end
  end

  test "review usage folds as role review under the reviewed subject" do
    :ok =
      ProjectionStore.apply_events([
        usage_event("run-r", "w1", %{}),
        %{
          event_type: "ReviewRecorded",
          payload: %{
            subject_kind: "run",
            subject_id: "run-r",
            project_id: "proj",
            verdict: "met",
            summary: "ok",
            at: "2026-01-01T12:00:00Z",
            model: "rev",
            usage_provider: "claude",
            usage: %{"input_tokens" => 7, "output_tokens" => 3, "total_tokens" => 10}
          }
        }
      ])

    usage = ProjectionStore.usage("proj")
    assert usage.by_role["review"].usage.total_tokens == 10
    assert usage.by_model["rev"].events == 1
    assert usage.by_thread["run-r"].bucket.events == 2
  end

  test "totals are identical live and after rebuilding the projection from the event log" do
    start_supervised!({ForemanServer.Overwatch.Tracker, []}, id: :tracker)
    id = "usage-replay-#{System.unique_integer([:positive])}"
    assert {:ok, _} = ForemanServer.ProjectStore.save(%{project_id: id, path: "/tmp/#{id}"})

    for {run, worker, extra} <- [
          {"r1", "w1", %{}},
          {"r1", "w2", %{model: nil}},
          {"r2", "w1", %{cost_usd: nil, at: "2026-01-02T00:00:00Z"}}
        ] do
      payload =
        Map.merge(
          %{
            run_id: "#{id}-#{run}",
            worker_id: "#{id}-#{run}-#{worker}",
            provider: "claude",
            project_id: id,
            model: "m1",
            input_tokens: 10,
            output_tokens: 5,
            total_tokens: 15,
            cost_usd: 0.01,
            at: "2026-01-01T10:00:00Z"
          },
          extra
        )

      assert :ok = ForemanServer.Overwatch.Tracker.dispatch_lifecycle("UsageRecorded", payload)
    end

    live = ProjectionStore.usage(id)
    assert live.total.events == 3
    assert live.total.cost_unknown_events == 1

    :ok = ProjectionStore.rebuild([])
    assert ProjectionStore.usage(id) == live
  end

  test "from/to restrict to whole UTC days" do
    :ok =
      ProjectionStore.apply_events([
        usage_event("run-1", "w1", %{at: "2026-01-01T23:59:59Z"}),
        usage_event("run-2", "w1", %{at: "2026-01-02T00:00:00Z"})
      ])

    assert ProjectionStore.usage("proj", from: "2026-01-02").total.events == 1
    assert ProjectionStore.usage("proj", to: "2026-01-01").total.events == 1
  end
end
