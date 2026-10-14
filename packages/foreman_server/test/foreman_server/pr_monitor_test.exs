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

    {:ok, _} = PrMonitor.start_link([])
    :ok
  end

  describe "interval and enabled helpers" do
    test "interval_ms/0 returns env override when set" do
      original = Application.get_env(:foreman_server, :pr_monitor_interval_ms)

      Application.put_env(:foreman_server, :pr_monitor_interval_ms, 60_000)
      assert PrMonitor.interval_ms() == 60_000

      Application.put_env(:foreman_server, :pr_monitor_interval_ms, original)
    end

    test "interval_ms/0 returns default 5 minutes when unset" do
      original = Application.get_env(:foreman_server, :pr_monitor_interval_ms)
      Application.delete_env(:foreman_server, :pr_monitor_interval_ms)
      assert PrMonitor.interval_ms() == 300_000
      Application.put_env(:foreman_server, :pr_monitor_interval_ms, original)
    end

    test "enabled?/0 reflects env" do
      original = Application.get_env(:foreman_server, :pr_monitor_enabled)
      Application.put_env(:foreman_server, :pr_monitor_enabled, true)
      assert PrMonitor.enabled?() == true
      Application.put_env(:foreman_server, :pr_monitor_enabled, false)
      refute PrMonitor.enabled?() == true
      Application.put_env(:foreman_server, :pr_monitor_enabled, original)
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
      run_id = "run-pr-monitor-#{System.unique_integer([:positive])}"
      pr_url = "https://github.com/acme/repo/pull/#{System.unique_integer([:positive])}"
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
      second_url = ctx.pr_url <> "9"
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
end
