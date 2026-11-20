defmodule ForemanServer.PrWatcherFollowUpTest do
  @moduledoc """
  With the `followup_runs` gate on, the fix reactor of `ForemanServer.PrWatcher` starts a FOLLOW-UP
  RUN instead of a jobsite: the same PR fix plan (head branch, push, agent, prompt), recorded as
  `PrFixStarted.fix_run_id`, finished when that run ends. Seams as in `PrWatcherFixTest`: a recording
  starter and a fake `gh`; the event store, aggregate, projection, git repo and `PrFix.plan/4` are real.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.{FollowUpRuns, PrWatcher, ProjectionStore}
  alias ForemanServer.TestSupport.PrFixSupport, as: Fix
  alias ForemanServer.TestSupport.PrWatchSupport, as: Support
  alias ForemanServer.Workflow.FollowUp

  setup do
    # on by default; a test that turns it off must leave it on
    FollowUpRuns.enable!()
    on_exit(&FollowUpRuns.enable!/0)

    :ok = ProjectionStore.subscribe(replay_existing: false)
    test_pid = self()
    {:ok, github} = Agent.start_link(fn -> nil end)
    on_exit(fn -> if Process.alive?(github), do: Agent.stop(github) end)

    followup = fn request ->
      send(test_pid, {:followup_start, request})
      {:ok, request.run_id}
    end

    ctx = Fix.watched!([])
    Agent.update(github, fn _ -> ctx.status end)
    fetch = fn _url -> Agent.get(github, &{:ok, &1}) end

    start_supervised!(
      {PrWatcher,
       [
         fetch_fun: fetch,
         followup_starter: followup,
         plan_opts: [fetch_fun: fetch, log_fetcher: fn _url, _check -> {:error, :none} end]
       ]}
    )

    %{ctx: ctx, github: github}
  end

  defp request_fix!(ctx, payload \\ %{}) do
    Support.dispatch!(%{
      type: "run.pr.fix_ci",
      command_id: "fix-#{ctx.run_id}-#{System.unique_integer([:positive])}",
      aggregate_id: "run:#{ctx.run_id}",
      payload: Map.merge(%{run_id: ctx.run_id, pr_url: ctx.pr_url}, payload)
    })
  end

  defp data(%{data: data}) when is_map(data), do: data
  defp data(%{payload: payload}) when is_map(payload), do: payload

  defp await_event(type, run_id, timeout \\ 10_000) do
    receive do
      {:projection_event, %{event_type: ^type} = event} ->
        if data(event)[:run_id] == run_id,
          do: data(event),
          else: await_event(type, run_id, timeout)

      {:projection_event, _other} ->
        await_event(type, run_id, timeout)
    after
      timeout -> flunk("no #{type} event for #{run_id} within #{timeout}ms")
    end
  end

  defp await_registered(id, attempts \\ 200_000) do
    cond do
      Map.has_key?(:sys.get_state(PrWatcher).fixes, id) -> :ok
      attempts == 0 -> flunk("watcher never registered #{id}")
      true -> await_registered(id, attempts - 1)
    end
  end

  defp end_run!(type, run_id, extra \\ %{}) do
    :ok =
      ProjectionStore.apply_events([
        %{event_type: type, payload: Map.merge(%{run_id: run_id}, extra)}
      ])
  end

  test "the fix becomes a follow-up request attached to the PR head, not a jobsite", %{ctx: ctx} do
    request_fix!(ctx, %{note: "keep the diff small"})

    assert_receive {:followup_start, request}, 10_000

    assert request.attach_branch == ctx.status.head_branch
    assert request.push == true
    assert request.kind == "pr_fix"
    assert request.fix_kind == "ci"
    assert request.parent_run_id == ctx.run_id
    assert request.pr_url == ctx.pr_url
    assert request.project_id
    assert request.repo_path == ctx.repo
    assert request.prompt =~ "keep the diff small"

    assert request.run_id ==
             FollowUp.run_id(ctx.run_id, ctx.pr_url, "ci", 1)

    started = await_event("PrFixStarted", ctx.run_id)
    assert started.fix_run_id == request.run_id

    # the projection records the run as the one fix in flight for the PR (no jobsite id to read it from)
    assert [%{fix: %{in_flight: in_flight}}] = ProjectionStore.pr_watch(ctx.run_id)
    assert in_flight == request.run_id
    refute Map.has_key?(started, :jobsite_id)
    assert started.kind == "ci"
  end

  test "the follow-up run's completion finishes the fix from the PR itself", %{
    ctx: ctx,
    github: github
  } do
    request_fix!(ctx)
    assert_receive {:followup_start, %{run_id: fix_run_id}}, 10_000
    await_event("PrFixStarted", ctx.run_id)
    await_registered(fix_run_id)

    Agent.update(github, fn _ ->
      %{ctx.status | head_sha: "sha-2", checks_state: :passing, checks: []}
    end)

    end_run!("RunCompleted", fix_run_id)

    finished = await_event("PrFixFinished", ctx.run_id)
    assert finished.outcome == "pushed"
    assert finished.new_head_sha == "sha-2"
  end

  test "a failed follow-up run is `failed` with a run code", %{ctx: ctx} do
    request_fix!(ctx)
    assert_receive {:followup_start, %{run_id: fix_run_id}}, 10_000
    await_event("PrFixStarted", ctx.run_id)
    await_registered(fix_run_id)

    end_run!("RunFailed", fix_run_id)

    finished = await_event("PrFixFinished", ctx.run_id)
    assert finished.outcome == "failed"
    assert finished.error_code == "run_failed"
  end

  test "a run this watcher did not start for a fix is ignored", %{ctx: ctx} do
    request_fix!(ctx)
    assert_receive {:followup_start, _}, 10_000
    await_event("PrFixStarted", ctx.run_id)

    end_run!("RunCompleted", "run-someone-else")

    refute_receive {:projection_event, %{event_type: "PrFixFinished"}}, 300
  end

  test "a request that cannot be recorded finishes the fix as failed", %{ctx: ctx} do
    :ok = stop_supervised(PrWatcher)
    github = ctx.status

    start_supervised!(
      {PrWatcher,
       [
         fetch_fun: fn _ -> {:ok, github} end,
         followup_starter: fn _request -> {:error, :followup_runs_disabled} end,
         plan_opts: [
           fetch_fun: fn _ -> {:ok, github} end,
           log_fetcher: fn _url, _check -> {:error, :none} end
         ]
       ]}
    )

    request_fix!(ctx)

    finished = await_event("PrFixFinished", ctx.run_id)
    assert finished.outcome == "failed"
    assert finished.error_code == "followup_runs_disabled"
    refute "PrFixStarted" in Support.run_event_types(ctx.run_id)
  end
end
