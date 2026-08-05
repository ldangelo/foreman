defmodule ForemanServer.TriggerPollerTest do
  use ExUnit.Case, async: false

  alias ForemanServer.TriggerPoller

  setup do
    case Process.whereis(ForemanServer.Inbox.Poller) do
      nil ->
        {:ok, _pid} = ForemanServer.Inbox.Poller.start_link([])

      pid ->
        if not Process.alive?(pid),
          do: {:ok, _pid} = ForemanServer.Inbox.Poller.start_link([])
    end

    # Reset fetch_fun to default (no-op) on every test setup.
    :persistent_term.erase({TriggerPoller, :fetch_fun})

    prev = %{
      enabled: Application.get_env(:foreman_server, :trigger_poll_enabled),
      interval: Application.get_env(:foreman_server, :trigger_poll_interval_ms),
      source: Application.get_env(:foreman_server, :trigger_poll_source_module)
    }

    Application.put_env(:foreman_server, :trigger_poll_enabled, false)

    Application.put_env(
      :foreman_server,
      :trigger_poll_source_module,
      ForemanServer.TriggerPoller.StubSource
    )

    on_exit(fn ->
      :persistent_term.erase({TriggerPoller, :fetch_fun})

      for {key, value} <- prev do
        case value do
          nil -> Application.delete_env(:foreman_server, :"trigger_poll_#{key}")
          v -> Application.put_env(:foreman_server, :"trigger_poll_#{key}", v)
        end
      end
    end)

    # Force-load the source module so function_exported?/3 returns true
    # before TriggerPoller.poll_now is invoked.
    _ = Code.ensure_loaded(ForemanServer.TriggerPoller.StubSource)

    :ok
  end

  describe "start_link/1 + poll_now/0" do
    test "starts a GenServer and returns 0 when no fetch_fun is configured" do
      {:ok, _} = TriggerPoller.start_link([])
      assert TriggerPoller.poll_now() == 0
    end

    test "ingests fetched triggers via SharedInbox" do
      id = "fetch-#{System.unique_integer([:positive])}"

      TriggerPoller.set_fetch_fun(fn ->
        [%{"trigger_id" => id, "kind" => "deploy"}]
      end)

      {:ok, _} = TriggerPoller.start_link([])
      assert TriggerPoller.poll_now() == 1
    end

    test "isolates failures via rescue and returns 0" do
      TriggerPoller.set_fetch_fun(fn -> raise "boom" end)
      {:ok, _} = TriggerPoller.start_link([])
      assert TriggerPoller.poll_now() == 0
    end
  end

  describe "configuration helpers" do
    test "interval_ms reads from app env" do
      prev = Application.get_env(:foreman_server, :trigger_poll_interval_ms)
      Application.put_env(:foreman_server, :trigger_poll_interval_ms, 7_777)

      on_exit(fn ->
        Application.put_env(:foreman_server, :trigger_poll_interval_ms, prev)
      end)

      assert TriggerPoller.interval_ms() == 7_777
    end

    test "source_module returns the configured module" do
      custom = :"#{__MODULE__}.CustomSource#{System.unique_integer([:positive])}"

      Application.put_env(:foreman_server, :trigger_poll_source_module, custom)

      prev = Application.get_env(:foreman_server, :trigger_poll_source_module)

      on_exit(fn ->
        Application.put_env(:foreman_server, :trigger_poll_source_module, prev)
      end)

      assert TriggerPoller.source_module() == custom
    end
  end
end
