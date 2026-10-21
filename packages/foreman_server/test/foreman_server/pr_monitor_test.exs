defmodule ForemanServer.PrMonitorTest do
  use ExUnit.Case, async: false

  alias ForemanServer.GitHub.PrStatus
  alias ForemanServer.PrAssociate
  alias ForemanServer.PrMonitor

  setup do
    :persistent_term.erase({PrMonitor, :fetch_fun})

    on_exit(fn ->
      :persistent_term.erase({PrMonitor, :fetch_fun})
    end)

    # Supervised by ExUnit: the instance is terminated synchronously before the
    # next test's setup runs, so the registered name is always free again. A bare
    # `start_link/1` died asynchronously on the test process's exit signal; the
    # next test's `start_link` then saw the dying instance as `already_started`
    # and its first call failed with `noproc`.
    start_supervised!(PrMonitor)
    :ok
  end

  # `put_env(key, nil)` would leave a nil that shadows the default for every later test.
  defp restore_env(key, nil), do: Application.delete_env(:foreman_server, key)
  defp restore_env(key, value), do: Application.put_env(:foreman_server, key, value)

  describe "interval and enabled helpers" do
    test "interval_ms/0 returns env override when set" do
      original = Application.get_env(:foreman_server, :pr_monitor_interval_ms)

      Application.put_env(:foreman_server, :pr_monitor_interval_ms, 60_000)
      assert PrMonitor.interval_ms() == 60_000

      restore_env(:pr_monitor_interval_ms, original)
    end

    test "interval_ms/0 returns default 5 minutes when unset" do
      original = Application.get_env(:foreman_server, :pr_monitor_interval_ms)
      Application.delete_env(:foreman_server, :pr_monitor_interval_ms)
      assert PrMonitor.interval_ms() == 300_000
      restore_env(:pr_monitor_interval_ms, original)
    end

    test "enabled?/0 reflects env" do
      original = Application.get_env(:foreman_server, :pr_monitor_enabled)
      Application.put_env(:foreman_server, :pr_monitor_enabled, true)
      assert PrMonitor.enabled?() == true
      Application.put_env(:foreman_server, :pr_monitor_enabled, false)
      refute PrMonitor.enabled?() == true
      restore_env(:pr_monitor_enabled, original)
    end
  end

  describe "stats/0" do
    test "returns a state map with last_run_at, last_count, last_errors" do
      stats = PrMonitor.stats()
      assert is_map(stats)
      assert Map.has_key?(stats, :last_count)
      assert Map.has_key?(stats, :last_errors)
    end
  end

  describe "poll_now/0 against a real run" do
    # Drives the real aggregate and event store. `run.pr.update` needs
    # project_id/task_id/branch_name/head_sha/base_branch; an earlier payload
    # carried none of them, so the aggregate rejected every update while
    # `poll_now/0` still counted it as a success.
    setup do
      # The event store outlives the VM and `unique_integer/1` restarts at 1 on
      # every boot, so a bare counter reuses ids (and PR URLs) of earlier runs'
      # persisted associations. A random token keeps this test's run and URLs its own.
      token = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      run_id = "run-pr-monitor-#{token}"
      pr_url = "https://github.com/acme/repo-#{token}/pull/1"
      started = %{run_id: run_id, project_id: "project-pr-monitor", task_id: "task-pr-monitor"}

      :ok =
        ForemanServer.EventStore.append_to_stream("run:#{run_id}", 0, [
          %EventStore.EventData{event_type: "RunStarted", data: started, metadata: %{}}
        ])

      :ok =
        ForemanServer.ProjectionStore.apply_events([
          %{event_type: "RunStarted", payload: started}
        ])

      {:ok, ^run_id} = PrAssociate.store(run_id, pr_url)

      %{run_id: run_id, pr_url: pr_url}
    end

    # Other tests share the event store and may have left PR associations
    # behind; answer only for this test's URL so counts are about this run.
    defp stub_for(pr_url, result) do
      PrMonitor.set_fetch_fun(fn
        ^pr_url -> result
        _other -> {:error, :not_this_test}
      end)
    end

    defp status(overrides \\ []) do
      struct!(
        %PrStatus{
          status: :open,
          head_sha: "abc123",
          head_branch: "foreman/task-pr-monitor/run",
          base_branch: "main"
        },
        overrides
      )
    end

    defp pr_updated_events(run_id) do
      {:ok, events} = ForemanServer.EventStore.read_stream_forward("run:#{run_id}", 0, 1_000)
      Enum.filter(events, &(&1.event_type == "PrUpdated"))
    end

    test "an observed PR state is appended to the run and counted as dispatched", ctx do
      stub_for(ctx.pr_url, {:ok, status()})

      assert PrMonitor.poll_now() == 1

      assert [event] = pr_updated_events(ctx.run_id)
      assert event.data.pr_url == ctx.pr_url
      assert event.data.head_sha == "abc123"
      assert event.data.base_branch == "main"
      assert event.data.project_id == "project-pr-monitor"
      assert event.data.task_id == "task-pr-monitor"
    end

    test "polling the same observation again appends nothing new", ctx do
      stub_for(ctx.pr_url, {:ok, status()})

      assert PrMonitor.poll_now() == 1
      assert PrMonitor.poll_now() == 1

      assert [_one] = pr_updated_events(ctx.run_id),
             "an unchanged PR must not grow the event log on every poll"
    end

    test "a changed head sha is a new observation and appends a second event", ctx do
      stub_for(ctx.pr_url, {:ok, status(head_sha: "aaa111")})
      assert PrMonitor.poll_now() == 1

      stub_for(ctx.pr_url, {:ok, status(head_sha: "bbb222")})
      assert PrMonitor.poll_now() == 1

      assert [_, _] = pr_updated_events(ctx.run_id)
    end

    test "a second PR URL on the same run is observed even at an identical status and head",
         ctx do
      second_url = String.replace_suffix(ctx.pr_url, "/pull/1", "/pull/2")
      stub_for(ctx.pr_url, {:ok, status()})
      assert PrMonitor.poll_now() == 1

      {:ok, _} = PrAssociate.store(ctx.run_id, second_url)
      stub_for(second_url, {:ok, status()})
      assert PrMonitor.poll_now() == 1

      urls = ctx.run_id |> pr_updated_events() |> Enum.map(& &1.data.pr_url) |> Enum.sort()
      assert urls == Enum.sort([ctx.pr_url, second_url])
    end

    test "a retargeted base branch at the same head is a new observation", ctx do
      stub_for(ctx.pr_url, {:ok, status(base_branch: "main")})
      assert PrMonitor.poll_now() == 1

      stub_for(ctx.pr_url, {:ok, status(base_branch: "release")})
      assert PrMonitor.poll_now() == 1

      bases = ctx.run_id |> pr_updated_events() |> Enum.map(& &1.data.base_branch)
      assert bases == ["main", "release"]
    end

    test "a fetch failure appends nothing and is counted as an error", ctx do
      stub_for(ctx.pr_url, {:error, {:gh_failed, 1, "boom"}})

      assert PrMonitor.poll_now() == 0
      assert pr_updated_events(ctx.run_id) == []
      assert %{last_count: 0, last_errors: errors} = PrMonitor.stats()
      assert errors >= 1
    end
  end

  describe "next_interval/3 (spike S4 schedule)" do
    @now 10_000_000_000

    defp record(overrides) do
      Map.merge(%{checks_state: "passing", updated_at: @now - 3_600_000}, Map.new(overrides))
    end

    test "running checks poll fastest, a recent change next, stable at the interval, idle slowest" do
      assert PrMonitor.next_interval(record(checks_state: "pending"), @now, jitter: 0.0) == 30_000

      assert PrMonitor.next_interval(record(updated_at: @now - 60_000), @now, jitter: 0.0) ==
               60_000

      assert PrMonitor.next_interval(record([]), @now, jitter: 0.0) == PrMonitor.interval_ms()

      assert PrMonitor.next_interval(record(updated_at: @now - 25 * 3_600_000), @now, jitter: 0.0) ==
               15 * 60_000
    end

    test "pending wins over idleness and a PR never observed uses the stable interval" do
      assert PrMonitor.next_interval(record(checks_state: "pending", updated_at: 1), @now,
               jitter: 0.0
             ) == 30_000

      assert PrMonitor.next_interval(record(updated_at: nil), @now, jitter: 0.0) ==
               PrMonitor.interval_ms()
    end

    test "jitter stays within +/-10%" do
      intervals = for _ <- 1..200, do: PrMonitor.next_interval(record([]), @now)
      base = PrMonitor.interval_ms()
      assert Enum.all?(intervals, &(&1 >= base * 0.9 - 1 and &1 <= base * 1.1 + 1))
      assert length(Enum.uniq(intervals)) > 1
    end
  end

  describe "scheduled ticks" do
    setup do
      token = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

      runs =
        for n <- 1..3,
            do:
              ForemanServer.TestSupport.PrWatchSupport.start_run!(
                project_id: "p-tick-#{token}-#{n}",
                complete: true
              )

      for run <- runs, do: {:ok, _} = PrAssociate.store(run.run_id, run.pr_url)
      %{runs: runs}
    end

    test "a tick observes at most max_per_tick due PRs; poll_now ignores the cap", %{runs: runs} do
      Application.put_env(:foreman_server, :pr_monitor_max_per_tick, 2)
      on_exit(fn -> Application.delete_env(:foreman_server, :pr_monitor_max_per_tick) end)
      test_pid = self()

      PrMonitor.set_fetch_fun(fn url ->
        send(test_pid, {:fetched, url})
        {:ok, %PrStatus{status: :open, head_sha: "s", head_branch: "b", base_branch: "main"}}
      end)

      send(Process.whereis(PrMonitor), :poll)
      %{last_count: count, last_errors: errors} = PrMonitor.stats()
      assert count + errors == 2

      assert PrMonitor.poll_now() >= length(runs)
    end

    test "merged and closed PRs are not polled", %{runs: [run | _]} do
      ForemanServer.ProjectionStore.apply_events([
        %{
          event_type: "PrMerged",
          payload: %{
            run_id: run.run_id,
            pr_url: run.pr_url,
            project_id: run.project_id,
            task_id: run.task_id
          }
        }
      ])

      test_pid = self()

      PrMonitor.set_fetch_fun(fn url ->
        send(test_pid, {:fetched, url})
        {:error, :stub}
      end)

      PrMonitor.poll_now()
      pr_url = run.pr_url
      refute_received {:fetched, ^pr_url}
    end

    defp open_status,
      do: %PrStatus{status: :open, head_sha: "s", head_branch: "b", base_branch: "main"}

    # Every `:fetched` message queued so far.
    defp fetched_urls(acc \\ []) do
      receive do
        {:fetched, url} -> fetched_urls([url | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    test "a 403 that does not mention a rate limit does not pause polling" do
      PrMonitor.set_fetch_fun(fn _url ->
        {:error, {:gh_failed, 1, "HTTP 403: Resource not accessible by integration"}}
      end)

      PrMonitor.poll_now()

      assert %{last_errors: errors, paused_until: nil} = PrMonitor.stats()
      assert errors >= 1
    end

    test "a rate limit pauses polling and stops the sweep at once" do
      test_pid = self()

      PrMonitor.set_fetch_fun(fn url ->
        send(test_pid, {:fetched, url})
        {:error, {:gh_failed, 1, "HTTP 403: API rate limit exceeded"}}
      end)

      PrMonitor.poll_now()

      assert %{last_errors: 1, paused_until: until} = PrMonitor.stats()
      assert is_integer(until)
      # the three watched PRs of this test were not all hit: the sweep halted
      assert [_one] = fetched_urls()
    end

    test "entries of PRs that are no longer watched are pruned from the schedule", %{
      runs: [run | rest]
    } do
      PrMonitor.set_fetch_fun(fn _url -> {:ok, open_status()} end)
      PrMonitor.poll_now()
      assert %{due: due} = PrMonitor.stats()
      assert Map.has_key?(due, run.pr_url)

      ForemanServer.ProjectionStore.apply_events([
        %{
          event_type: "PrMerged",
          payload: %{
            run_id: run.run_id,
            pr_url: run.pr_url,
            project_id: run.project_id,
            task_id: run.task_id
          }
        }
      ])

      PrMonitor.poll_now()
      assert %{due: due} = PrMonitor.stats()
      refute Map.has_key?(due, run.pr_url)
      assert Enum.all?(rest, &Map.has_key?(due, &1.pr_url))
    end

    test "PRs the per-tick cap left over are polled on the next second, not a full interval later",
         %{runs: runs} do
      Application.put_env(:foreman_server, :pr_monitor_max_per_tick, 1)
      on_exit(fn -> Application.delete_env(:foreman_server, :pr_monitor_max_per_tick) end)
      test_pid = self()

      PrMonitor.set_fetch_fun(fn url ->
        send(test_pid, {:fetched, url})
        {:ok, open_status()}
      end)

      send(Process.whereis(PrMonitor), :poll)

      # only the first tick is triggered by hand; the rest follow from the schedule
      for run <- runs, do: assert_receive({:fetched, url} when url == run.pr_url, 20_000)
    end
  end
end
