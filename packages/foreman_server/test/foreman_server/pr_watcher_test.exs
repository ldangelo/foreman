defmodule ForemanServer.PrWatcherTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{PrAssociate, PrWatcher, ProjectionStore}
  alias ForemanServer.TestSupport.PrWatchSupport, as: Support

  # The fetch function is driven from an Agent so a test can change what "GitHub"
  # reports and count how often it was asked.
  defp start_github(initial) do
    {:ok, agent} = Agent.start_link(fn -> %{status: initial, fetches: 0} end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    fetch = fn _url ->
      Agent.get_and_update(agent, fn s -> {s.status, %{s | fetches: s.fetches + 1}} end)
    end

    {agent, fetch}
  end

  defp set_status(agent, status), do: Agent.update(agent, &%{&1 | status: status})
  defp fetches(agent), do: Agent.get(agent, & &1.fetches)

  defp failing,
    do: {:ok, Support.status(checks: [Support.failing_check("unit")], checks_state: :failing)}

  defp passing do
    check = %{Support.failing_check("unit") | state: :passing, conclusion: "SUCCESS"}
    {:ok, Support.status(checks: [check], checks_state: :passing)}
  end

  defp checks_events(run_id),
    do: Enum.filter(Support.run_events(run_id), &(&1.event_type == "PrChecksChanged"))

  setup do
    :ok = ProjectionStore.subscribe(replay_existing: false)
    {:ok, Support.start_run!(complete: true)}
  end

  test "associating a PR observes it immediately, once, without waiting for a poll", ctx do
    {_agent, fetch} = start_github(failing())
    start_supervised!({PrWatcher, fetch_fun: fetch})

    {:ok, _} = PrAssociate.store(ctx.run_id, ctx.pr_url)

    assert_receive {:projection_event, %{event_type: "PrChecksChanged", data: %{run_id: run_id}}},
                   5_000

    assert run_id == ctx.run_id

    assert [%{data: %{checks_state: "failing", failing: [%{name: "unit"}]}}] =
             checks_events(ctx.run_id)
  end

  test "refresh_now with an identical status appends nothing; a flip appends each change", ctx do
    {agent, fetch} = start_github(failing())
    {:ok, _} = PrAssociate.store(ctx.run_id, ctx.pr_url)
    start_supervised!({PrWatcher, fetch_fun: fetch})

    assert {:ok, %{dispatched: first}} = PrWatcher.refresh_now(ctx.pr_url)
    assert "run.pr.checks" in first
    assert {:ok, %{dispatched: []}} = PrWatcher.refresh_now(ctx.pr_url)
    assert length(checks_events(ctx.run_id)) == 1

    set_status(agent, passing())
    assert {:ok, %{dispatched: ["run.pr.checks"]}} = PrWatcher.refresh_now(ctx.pr_url)
    set_status(agent, failing())
    assert {:ok, %{dispatched: ["run.pr.checks"]}} = PrWatcher.refresh_now(ctx.pr_url)

    assert length(checks_events(ctx.run_id)) == 3
  end

  test "an event of another type causes no fetch", ctx do
    {agent, fetch} = start_github(failing())
    start_supervised!({PrWatcher, fetch_fun: fetch})

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "RunStarted",
          payload: %{run_id: "run-other", task_id: "t", project_id: "p", workflow_snapshot: %{}}
        },
        %{
          event_type: "PrUpdated",
          payload: %{run_id: ctx.run_id, pr_url: ctx.pr_url, pr_status: "open", head_sha: "x"}
        }
      ])

    # `stats/1` is a call: it is served after the mailbox events above were handled.
    assert %{observations: 0, errors: 0} = PrWatcher.stats()
    assert fetches(agent) == 0
  end

  test "a rejected dispatch is an error and is counted, never a success", ctx do
    {_agent, fetch} = start_github(failing())
    start_supervised!({PrWatcher, fetch_fun: fetch})

    # Associated in the read model only: the run projection lacks the project/task ids
    # every PR command needs, so the observation is refused.
    ghost = "run-ghost-#{System.unique_integer([:positive])}"
    url = "https://github.com/acme/ghost/pull/#{System.unique_integer([:positive])}"

    :ok =
      ProjectionStore.apply_events([
        %{event_type: "PrAssociated", payload: %{run_id: ghost, pr_url: url}}
      ])

    assert {:error,
            {:dispatch_failed, [{^ghost, "observation", {:run_projection_missing_ids, ^ghost}}]}} =
             PrWatcher.refresh_now(url)

    assert %{observations: 0, errors: 1} = PrWatcher.stats()
    assert ctx.run_id
  end

  test "a watcher started after a PR was associated does not replay history", ctx do
    {agent, fetch} = start_github(failing())
    {:ok, _} = PrAssociate.store(ctx.run_id, ctx.pr_url)

    start_supervised!({PrWatcher, fetch_fun: fetch})
    assert %{observations: 0} = PrWatcher.stats()
    assert fetches(agent) == 0
  end

  test "concurrent refresh_now for one PR collapse to one fetch", ctx do
    test_pid = self()

    fetch = fn url ->
      send(test_pid, {:fetching, self(), url})

      receive do
        :go -> failing()
      end
    end

    {:ok, _} = PrAssociate.store(ctx.run_id, ctx.pr_url)
    start_supervised!({PrWatcher, fetch_fun: fetch})

    first = Task.async(fn -> PrWatcher.refresh_now(ctx.pr_url) end)
    assert_receive {:fetching, fetcher, _}, 5_000

    second = Task.async(fn -> PrWatcher.refresh_now(ctx.pr_url) end)
    # the second caller is registered with the watcher before the fetch is released
    :sys.get_state(PrWatcher)
    send(fetcher, :go)

    assert {:ok, result} = Task.await(first, 10_000)
    assert {:ok, ^result} = Task.await(second, 10_000)
    refute_received {:fetching, _, _}
    assert length(checks_events(ctx.run_id)) == 1
  end

  test "a merged PR ends the watch; an operator-stopped watch is not observed at all", ctx do
    {agent, fetch} = start_github(failing())
    {:ok, _} = PrAssociate.store(ctx.run_id, ctx.pr_url)
    start_supervised!({PrWatcher, fetch_fun: fetch})

    assert {:ok, _} = PrWatcher.refresh_now(ctx.pr_url)
    assert [%{watching: true}] = ProjectionStore.pr_watch(ctx.run_id)

    set_status(agent, {:ok, Support.status(status: :merged)})
    assert {:ok, %{dispatched: dispatched}} = PrWatcher.refresh_now(ctx.pr_url)
    assert "run.pr.watch_stop" in dispatched

    assert [%{watching: false, stop_reason: "merged", status: "merged"}] =
             ProjectionStore.pr_watch(ctx.run_id)

    assert Enum.reject(ProjectionStore.watched_prs(), &(&1.pr_url != ctx.pr_url)) == []

    # a merged watch is final: no further fetch for it
    before = fetches(agent)
    assert {:error, :not_watched} = PrWatcher.refresh_now(ctx.pr_url)
    assert fetches(agent) == before
  end

  test "a closed PR that is reopened resumes the watch", ctx do
    {agent, fetch} = start_github({:ok, Support.status(status: :closed)})
    {:ok, _} = PrAssociate.store(ctx.run_id, ctx.pr_url)
    start_supervised!({PrWatcher, fetch_fun: fetch})

    assert {:ok, _} = PrWatcher.refresh_now(ctx.pr_url)
    assert [%{watching: false, stop_reason: "closed"}] = ProjectionStore.pr_watch(ctx.run_id)

    set_status(agent, {:ok, Support.status(status: :open, head_sha: "sha-reopened")})
    assert {:ok, %{dispatched: dispatched}} = PrWatcher.refresh_now(ctx.pr_url)
    assert "run.pr.watch_start" in dispatched
    assert [%{watching: true, status: "open"}] = ProjectionStore.pr_watch(ctx.run_id)
  end

  test "gh missing is reported in stats and the watcher stays up", ctx do
    {:ok, _} = PrAssociate.store(ctx.run_id, ctx.pr_url)
    pid = start_supervised!({PrWatcher, fetch_fun: fn _ -> {:error, :gh_not_installed} end})

    assert {:error, :gh_not_installed} = PrWatcher.refresh_now(ctx.pr_url)
    assert %{errors: 1, last_error: :gh_not_installed} = PrWatcher.stats()
    assert Process.alive?(pid)
  end

  test "a crashing fetch is an error, not a crashed watcher", ctx do
    {:ok, _} = PrAssociate.store(ctx.run_id, ctx.pr_url)
    pid = start_supervised!({PrWatcher, fetch_fun: fn _ -> raise "boom" end})

    assert {:error, {:fetch_crashed, "boom"}} = PrWatcher.refresh_now(ctx.pr_url)
    assert Process.alive?(pid)
  end
end
