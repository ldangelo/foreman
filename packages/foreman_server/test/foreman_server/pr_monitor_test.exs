defmodule ForemanServer.PrMonitorTest do
  use ExUnit.Case, async: false

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

  describe "fetch_fun injection" do
    test "default fetch_fun returns :not_configured" do
      :persistent_term.erase({PrMonitor, :fetch_fun})
      assert {:error, :not_configured} = PrMonitor.fetch_fun().("https://example.com/x")
    end

    test "set_fetch_fun/1 overrides the default" do
      PrMonitor.set_fetch_fun(fn url ->
        if String.contains?(url, "merged") do
          {:ok, :merged}
        else
          {:error, :not_found}
        end
      end)

      assert {:ok, :merged} = PrMonitor.fetch_fun().("merged-url")
      assert {:error, :not_found} = PrMonitor.fetch_fun().("foo")
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

  describe "poll_now/0" do
    test "is a synchronous barrier that returns the count dispatched" do
      assert is_integer(PrMonitor.poll_now())
    end
  end
end
