defmodule ForemanServer.PrWatcherFixTest do
  @moduledoc """
  The fix reactor of `ForemanServer.PrWatcher` (E9-S3/S4): a persisted
  `PrFixRequested` starts exactly one push-enabled jobsite on the PR head branch,
  `PrFixStarted`/`PrFixFinished` record what happened, and a restart neither
  duplicates a running fix nor loses it. Seams: a recording jobsite starter and a
  fake `gh` (the fetch function) - everything else (event store, aggregate,
  projection, git repo, `PrFix.plan/4`) is real.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.Jobsite.Error
  alias ForemanServer.{CommandGateway, PrWatcher, ProjectionStore}
  alias ForemanServer.PrWatcher.Observer
  alias ForemanServer.TestSupport.PrFixSupport, as: Fix
  alias ForemanServer.TestSupport.PrWatchSupport, as: Support

  setup do
    :ok = ProjectionStore.subscribe(replay_existing: false)
    test_pid = self()
    {:ok, github} = Agent.start_link(fn -> nil end)
    on_exit(fn -> if Process.alive?(github), do: Agent.stop(github) end)
    counter = :counters.new(1, [])

    starter = fn opts ->
      :counters.add(counter, 1, 1)
      id = "js-fix-#{:counters.get(counter, 1)}-#{System.unique_integer([:positive])}"
      send(test_pid, {:jobsite_start, id, opts})
      {:ok, id}
    end

    %{github: github, starter: starter}
  end

  defp fetch_fun(github), do: fn _url -> Agent.get(github, &{:ok, &1}) end

  defp github!(github, status), do: Agent.update(github, fn _ -> status end)

  defp start_watcher!(ctx, test_ctx, opts \\ []) do
    github = test_ctx.github

    start_supervised!(
      {PrWatcher,
       [
         fetch_fun: fetch_fun(github),
         jobsite_starter: Keyword.get(opts, :starter, test_ctx.starter),
         plan_opts: [
           fetch_fun: fetch_fun(github),
           log_fetcher: fn _url, _check -> {:error, :none} end
         ]
       ]}
    )

    ctx
  end

  defp setup_run!(%{github: github}, opts \\ []) do
    ctx = Fix.watched!(opts)
    github!(github, ctx.status)
    ctx
  end

  defp request_fix!(ctx, kind \\ "run.pr.fix_ci", payload \\ %{}) do
    Support.dispatch!(%{
      type: kind,
      command_id: "fix-#{ctx.run_id}-#{System.unique_integer([:positive])}",
      aggregate_id: "run:#{ctx.run_id}",
      payload: Map.merge(%{run_id: ctx.run_id, pr_url: ctx.pr_url}, payload)
    })
  end

  defp finish_jobsite!(type, jobsite_id, extra \\ %{}) do
    :ok =
      ProjectionStore.apply_events([
        %{event_type: type, payload: Map.merge(%{jobsite_id: jobsite_id}, extra)}
      ])
  end

  defp data(%{data: data}) when is_map(data), do: data
  defp data(%{payload: payload}) when is_map(payload), do: payload

  # The next projection event of `type` for `run_id`; others are skipped.
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

  # `PrFixStarted` is appended before the watcher registers the jobsite in its own state
  # (a jobsite that ends in between is settled from the projection instead, which
  # carries no failure code). Wait for the registration where the code matters.
  defp await_registered(jobsite_id, attempts \\ 200_000) do
    cond do
      Map.has_key?(:sys.get_state(PrWatcher).jobsites, jobsite_id) -> :ok
      attempts == 0 -> flunk("watcher never registered #{jobsite_id}")
      true -> await_registered(jobsite_id, attempts - 1)
    end
  end

  # Every message the watcher had queued was handled and every task it spawned for a
  # fix has finished: what remains is its settled state (no sleeping).
  defp await_idle(attempts \\ 200_000) do
    state = :sys.get_state(PrWatcher)

    cond do
      state.fix_tasks == %{} and MapSet.size(state.starting) == 0 -> :ok
      attempts == 0 -> flunk("watcher never went idle")
      true -> await_idle(attempts - 1)
    end
  end

  defp assert_started!(jobsite_id_pattern \\ nil) do
    assert_receive {:jobsite_start, id, opts}, 10_000
    if jobsite_id_pattern, do: assert(id == jobsite_id_pattern)
    {id, opts}
  end

  # The start task dies: the fix is finished as failed, the crash is logged with its reason,
  # and the PR takes a new request (nothing stays "in flight" until the next restart).
  defp assert_start_crash_finishes_fix!(tc, starter, logged_reason) do
    ctx = setup_run!(tc)
    start_watcher!(ctx, tc, starter: starter)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        request_fix!(ctx)

        finished = await_event("PrFixFinished", ctx.run_id)
        assert finished.outcome == "failed"
        assert finished.error_code == "start_crashed"
        await_idle()
      end)

    # the defect is not swallowed: the crash is logged with its reason
    assert log =~ "PrWatcher fix task"
    assert log =~ "crashed: " <> logged_reason

    assert [%{fix: %{in_flight: nil}}] = ProjectionStore.pr_watch(ctx.run_id)
    # the PR is free again: the aggregate accepts a new request (dispatch! raises on refusal)
    request_fix!(ctx)
    assert await_event("PrFixFinished", ctx.run_id).error_code == "start_crashed"
  end

  describe "starting a fix" do
    test "one push-enabled jobsite on the PR head branch, then PrFixStarted records its id", tc do
      ctx = setup_run!(tc)
      start_watcher!(ctx, tc)

      request_fix!(ctx, "run.pr.fix_ci", %{note: "keep the diff small"})

      {jobsite_id, opts} = assert_started!()
      head = ctx.status.head_branch

      assert opts[:strategy] == {:branch, head}
      assert opts[:push] == true
      assert opts[:sync_remote] == "origin"
      assert opts[:repo_path] == ctx.repo
      assert opts[:prompt] =~ "unit"
      assert opts[:prompt] =~ "keep the diff small"

      started = await_event("PrFixStarted", ctx.run_id)
      assert started.jobsite_id == jobsite_id
      assert started.kind == "ci"
      assert started.pr_url == ctx.pr_url
    end

    test "a re-delivered PrFixRequested does not start a second jobsite", tc do
      ctx = setup_run!(tc)
      start_watcher!(ctx, tc)
      pid = Process.whereis(PrWatcher)

      run_id = ctx.run_id
      request_fix!(ctx)

      assert_receive {:projection_event,
                      %{event_type: "PrFixRequested", data: %{run_id: ^run_id}} = requested},
                     10_000

      assert_started!()
      await_event("PrFixStarted", ctx.run_id)
      # the start has fully settled (no longer "starting"): only the aggregate's record
      # of the fix can tell the watcher this request is already served
      await_idle()

      # at-least-once delivery from the projection: the same event again
      send(pid, {:projection_event, requested})
      await_idle()

      refute_receive {:jobsite_start, _, _}, 300
      assert Enum.count(Support.run_event_types(ctx.run_id), &(&1 == "PrFixStarted")) == 1
    end

    test "a jobsite that cannot start finishes the fix as failed with the error code; nothing is left in flight",
         tc do
      ctx = setup_run!(tc)

      starter = fn _opts -> {:error, Error.new(:spawn_failed, "no docker", %{})} end
      start_watcher!(ctx, tc, starter: starter)

      request_fix!(ctx)

      finished = await_event("PrFixFinished", ctx.run_id)
      assert finished.outcome == "failed"
      assert finished.error_code == "spawn_failed"
      refute "PrFixStarted" in Support.run_event_types(ctx.run_id)

      # the in-flight marker is cleared, so the operator can ask again
      assert [%{fix: %{in_flight: nil}}] = ProjectionStore.pr_watch(ctx.run_id)
    end

    test "a request the plan rejects (unsafe branch) finishes as failed with the typed code",
         tc do
      status = Support.status(head_branch: "--upload-pack=evil")
      ctx = setup_run!(tc, status: status)
      start_watcher!(ctx, tc)

      request_fix!(ctx)

      finished = await_event("PrFixFinished", ctx.run_id)
      assert finished.outcome == "failed"
      assert finished.error_code == "branch_unsafe"
      refute_receive {:jobsite_start, _, _}, 100
    end

    test "a start task that crashes finishes the fix as failed instead of leaving it in flight",
         tc do
      # not a `{:ok, id} | {:error, _}` shape: the start task raises CaseClauseError
      assert_start_crash_finishes_fix!(
        tc,
        fn _opts -> :unexpected end,
        "{{:case_clause, :unexpected}"
      )
    end

    test "a start task that is killed finishes the fix as failed too", tc do
      assert_start_crash_finishes_fix!(tc, fn _opts -> Process.exit(self(), :kill) end, ":killed")
    end
  end

  describe "outcomes" do
    test "a new head sha is `pushed`; the fresh observation is handed back to the policy", tc do
      ctx = setup_run!(tc)
      start_watcher!(ctx, tc)

      request_fix!(ctx)
      {jobsite_id, _opts} = assert_started!()
      await_event("PrFixStarted", ctx.run_id)

      github!(tc.github, %{ctx.status | head_sha: "sha-2", checks_state: :passing, checks: []})
      finish_jobsite!("JobsiteCompleted", jobsite_id)

      finished = await_event("PrFixFinished", ctx.run_id)
      assert finished.outcome == "pushed"
      assert finished.new_head_sha == "sha-2"
      assert finished.kind == "ci"

      # the re-observation reached the PR record (CI is now green at the new head)
      assert [%{head_sha: "sha-2"}] = ProjectionStore.pr_watch(ctx.run_id)
    end

    test "an unchanged head is `no_change`", tc do
      ctx = setup_run!(tc)
      start_watcher!(ctx, tc)

      request_fix!(ctx)
      {jobsite_id, _} = assert_started!()
      await_event("PrFixStarted", ctx.run_id)

      finish_jobsite!("JobsiteCompleted", jobsite_id)

      finished = await_event("PrFixFinished", ctx.run_id)
      assert finished.outcome == "no_change"
    end

    test "a failed jobsite is `failed` with its code", tc do
      ctx = setup_run!(tc)
      start_watcher!(ctx, tc)

      request_fix!(ctx)
      {jobsite_id, _} = assert_started!()
      await_event("PrFixStarted", ctx.run_id)
      await_registered(jobsite_id)

      finish_jobsite!("JobsiteFailed", jobsite_id, %{code: "agent_crashed", message: "boom"})

      finished = await_event("PrFixFinished", ctx.run_id)
      assert finished.outcome == "failed"
      assert finished.error_code == "agent_crashed"
    end

    test "an event of a jobsite this watcher did not start for a fix is ignored", tc do
      ctx = setup_run!(tc)
      start_watcher!(ctx, tc)

      finish_jobsite!("JobsiteCompleted", "js-someone-else")

      await_idle()
      run_id = ctx.run_id

      refute_receive {:projection_event,
                      %{event_type: "PrFixFinished", data: %{run_id: ^run_id}}},
                     200

      refute "PrFixFinished" in Support.run_event_types(ctx.run_id)
    end
  end

  describe "auto-fix loop (policy + reactor)" do
    test "at the attempt cap the loop stops and records PrFixExhausted instead of fixing again",
         tc do
      ctx =
        setup_run!(tc,
          settings: %{
            thread_model: "sonnet",
            pr_auto_fix: %{"kinds" => ["ci"], "max_attempts" => 1}
          }
        )

      start_watcher!(ctx, tc)

      # a failing observation under auto-fix requests the first (and only allowed) fix
      assert {:ok, _} = PrWatcher.refresh_now(ctx.pr_url)
      {jobsite_id, _} = assert_started!()
      requested = await_event("PrFixRequested", ctx.run_id)
      assert requested.attempt == 1
      assert requested.trigger == "auto"
      await_event("PrFixStarted", ctx.run_id)

      # the push moved the head but CI is still red
      github!(tc.github, %{ctx.status | head_sha: "sha-2"})
      finish_jobsite!("JobsiteCompleted", jobsite_id)

      assert await_event("PrFixFinished", ctx.run_id).outcome == "pushed"
      exhausted = await_event("PrFixExhausted", ctx.run_id)
      assert exhausted.kind == "ci"
      assert exhausted.reason == "max_attempts"
      assert exhausted.head_sha == "sha-2"

      refute_receive {:jobsite_start, _, _}, 300
      assert Enum.count(Support.run_event_types(ctx.run_id), &(&1 == "PrFixRequested")) == 1
    end

    test "a rejected PrFixExhausted dispatch is logged, not dropped", tc do
      ctx =
        setup_run!(tc,
          settings: %{
            thread_model: "sonnet",
            pr_auto_fix: %{"kinds" => ["ci"], "max_attempts" => 1}
          }
        )

      request_fix!(ctx, "run.pr.fix_ci", %{
        trigger: "auto",
        max_attempts: 1,
        requested_at: System.system_time(:millisecond)
      })

      Support.dispatch!(%{
        type: "run.pr.fix_started",
        command_id: "started-#{ctx.run_id}",
        aggregate_id: "run:#{ctx.run_id}",
        payload: %{run_id: ctx.run_id, pr_url: ctx.pr_url, jobsite_id: "js-cap"}
      })

      Support.dispatch!(%{
        type: "run.pr.fix_finished",
        command_id: "finished-#{ctx.run_id}",
        aggregate_id: "run:#{ctx.run_id}",
        payload: %{run_id: ctx.run_id, pr_url: ctx.pr_url, outcome: "failed"}
      })

      # The cap is used up, so the next automatic request is refused and the give-up is
      # recorded - but an empty head sha makes the aggregate reject that record too.
      status = %{ctx.status | head_sha: ""}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert [] = Observer.auto_fix([ctx.run_id], ctx.pr_url, status)
        end)

      assert log =~ "run.pr.fix_exhausted"
      assert log =~ ctx.run_id
      refute "PrFixExhausted" in Support.run_event_types(ctx.run_id)
    end
  end

  describe "restart recovery" do
    test "a fix that was running before the restart is not duplicated and its completion is still recorded",
         tc do
      ctx = setup_run!(tc)
      start_watcher!(ctx, tc)

      request_fix!(ctx)
      {jobsite_id, _} = assert_started!()
      await_event("PrFixStarted", ctx.run_id)

      :ok = stop_supervised(PrWatcher)
      start_watcher!(ctx, tc)

      # nothing was re-started for the fix that was already running
      await_idle()
      refute_receive {:jobsite_start, _, _}, 300

      # an at-most-one operator re-request is still refused by the aggregate
      assert {:error, {:fix_in_flight, _}} =
               CommandGateway.dispatch_system(%{
                 type: "run.pr.fix_ci",
                 command_id: "again-#{ctx.run_id}",
                 aggregate_id: "run:#{ctx.run_id}",
                 payload: %{run_id: ctx.run_id, pr_url: ctx.pr_url}
               })

      github!(tc.github, %{ctx.status | head_sha: "sha-2"})
      finish_jobsite!("JobsiteCompleted", jobsite_id)

      # the rebuilt in-flight fix is what makes this completion recordable
      finished = await_event("PrFixFinished", ctx.run_id)
      assert finished.outcome == "pushed"
    end

    test "a fix whose jobsite ended while the server was down is finished on boot", tc do
      ctx = setup_run!(tc)
      start_watcher!(ctx, tc)

      request_fix!(ctx)
      {jobsite_id, _} = assert_started!()
      await_event("PrFixStarted", ctx.run_id)

      :ok = stop_supervised(PrWatcher)
      finish_jobsite!("JobsiteFailed", jobsite_id, %{code: "oom"})

      start_watcher!(ctx, tc)

      finished = await_event("PrFixFinished", ctx.run_id)
      assert finished.outcome == "failed"
      # only the projected status survives a restart, not the failure code
      assert finished.error_code == "jobsite_failed"
      refute_receive {:jobsite_start, _, _}, 100
    end

    test "a request that never got a jobsite is finished as lost_on_restart, never started late",
         tc do
      ctx = setup_run!(tc)

      # no watcher is running: the request is persisted but nobody reacted to it
      request_fix!(ctx)
      assert "PrFixRequested" in Support.run_event_types(ctx.run_id)

      start_watcher!(ctx, tc)

      finished = await_event("PrFixFinished", ctx.run_id)
      assert finished.outcome == "failed"
      assert finished.error_code == "lost_on_restart"
      refute_receive {:jobsite_start, _, _}, 100
    end
  end
end
