defmodule ForemanServer.ConfigParityTest do
  @moduledoc """
  Verifies config/dev.exs satisfies TRD-022 AC-014-1:
  Given config/dev.exs is absent, when application starts in dev mode,
  then all required runtime configuration is present and loadable.
  """
  use ExUnit.Case, async: false

  @dev_config_path Path.join(__DIR__, "../config/config.exs") |> Path.expand()

  setup do
    original_env = %{
      "DATABASE_URL" => System.get_env("DATABASE_URL"),
      "FOREMAN_SERVER_HTTP_ENABLED" => System.get_env("FOREMAN_SERVER_HTTP_ENABLED")
    }

    System.delete_env("DATABASE_URL")
    System.delete_env("FOREMAN_SERVER_HTTP_ENABLED")

    on_exit(fn ->
      for {k, v} <- original_env, v != nil, do: System.put_env(k, v)
    end)

    :ok
  end

  describe "dev.exs — foreman_server config (via Config.Reader, env: :dev)" do
    test "EventStore adapter is :postgres in dev" do
      assert get_foreman_config([:event_store_adapter]) == :postgres
    end

    test "Repo URL falls back to local dev compose stack when no DATABASE_URL" do
      url = get_foreman_config([ForemanServer.Repo, :url])
      assert url != nil
      assert url =~ "localhost:55432" || url =~ "127.0.0.1:55432"
      assert url =~ "/foreman_dev"
    end

    test "HTTP enabled flag is true in dev" do
      assert get_foreman_config([:http_enabled]) == true
    end

    test "debug_errors is true in dev (Plug.Debugger active)" do
      assert get_foreman_config([:debug_errors]) == true
    end

    test "debug LiveView pages are enabled in dev" do
      assert get_foreman_config([:debug_live_views_enabled]) == true
    end

    test "scheduler worker_launcher consumed by Recovery.scheduler_env/2" do
      launcher = get_foreman_config([:scheduler, :worker_launcher])
      assert launcher == ForemanServer.WorkerLauncher
    end

    test "explicit dev HTTP port 4766 is set" do
      assert get_foreman_config([:http_port]) == 4766
    end
  end

  describe "dev.exs — logger (top-level, not under :foreman_server)" do
    test "logger level is :debug for verbose dev logging" do
      assert get_logger_level() == :debug
    end
  end

  describe "dev.exs — derived runtime configuration" do
    test "ProjectionStore adapter derives :postgres from dev EventStore + database_url config" do
      # ProjectionStore adapter is derived: :postgres when event_store=:postgres AND database_url is set.
      # Use the actual dev config values so this test fails if dev.exs changes those inputs.
      original_adapter_env = System.get_env("FOREMAN_SERVER_EVENT_STORE_ADAPTER")
      original_event_store_adapter = Application.get_env(:foreman_server, :event_store_adapter)
      original_database_url = Application.get_env(:foreman_server, :database_url)
      System.delete_env("FOREMAN_SERVER_EVENT_STORE_ADAPTER")

      try do
        Application.put_env(
          :foreman_server,
          :event_store_adapter,
          get_foreman_config([:event_store_adapter])
        )

        Application.put_env(:foreman_server, :database_url, get_foreman_config([:database_url]))

        assert ForemanServer.RuntimeInfo.projection_store_adapter() == :postgres
      after
        System.delete_env("FOREMAN_SERVER_EVENT_STORE_ADAPTER")

        if original_adapter_env,
          do: System.put_env("FOREMAN_SERVER_EVENT_STORE_ADAPTER", original_adapter_env)

        if is_nil(original_event_store_adapter) do
          Application.delete_env(:foreman_server, :event_store_adapter)
        else
          Application.put_env(:foreman_server, :event_store_adapter, original_event_store_adapter)
        end

        if is_nil(original_database_url) do
          Application.delete_env(:foreman_server, :database_url)
        else
          Application.put_env(:foreman_server, :database_url, original_database_url)
        end
      end
    end

    test "Overwatch GenServer is supervised and alive in the running app" do
      # {Overwatch, []} is in Application children; assert the named GenServer is alive.
      spec = ForemanServer.Overwatch.child_spec([])
      assert is_map(spec)
      assert spec.id == ForemanServer.Overwatch
      assert {ForemanServer.Overwatch, :start_link, [_]} = spec.start
      assert Process.alive?(Process.whereis(ForemanServer.Overwatch))
    end
  end

  describe "Endpoint — router selection driven by consumed debug config" do
    test "debug_live_views_enabled=true selects the Phoenix endpoint" do
      original_live = Application.get_env(:foreman_server, :debug_live_views_enabled)
      original_errors = Application.get_env(:foreman_server, :debug_errors)

      on_exit(fn ->
        if is_nil(original_live) do
          Application.delete_env(:foreman_server, :debug_live_views_enabled)
        else
          Application.put_env(:foreman_server, :debug_live_views_enabled, original_live)
        end

        if is_nil(original_errors) do
          Application.delete_env(:foreman_server, :debug_errors)
        else
          Application.put_env(:foreman_server, :debug_errors, original_errors)
        end
      end)

      Application.put_env(:foreman_server, :debug_live_views_enabled, true)
      Application.put_env(:foreman_server, :debug_errors, true)

      spec = ForemanServer.Http.Endpoint.child_spec(port: 0)
      assert {Bandit, :start_link, [options]} = spec.start
      assert options[:plug] == ForemanServerWeb.Endpoint
    end

    test "debug_errors=true selects DevRouter when LiveView debug pages are disabled" do
      original_live = Application.get_env(:foreman_server, :debug_live_views_enabled)
      original_errors = Application.get_env(:foreman_server, :debug_errors)

      on_exit(fn ->
        if is_nil(original_live) do
          Application.delete_env(:foreman_server, :debug_live_views_enabled)
        else
          Application.put_env(:foreman_server, :debug_live_views_enabled, original_live)
        end

        if is_nil(original_errors) do
          Application.delete_env(:foreman_server, :debug_errors)
        else
          Application.put_env(:foreman_server, :debug_errors, original_errors)
        end
      end)

      Application.put_env(:foreman_server, :debug_live_views_enabled, false)
      Application.put_env(:foreman_server, :debug_errors, true)

      spec = ForemanServer.Http.Endpoint.child_spec(port: 0)
      assert {Bandit, :start_link, [options]} = spec.start
      assert options[:plug] == ForemanServer.Http.DevRouter
    end

    test "debug_errors=false selects plain Router when LiveView debug pages are disabled" do
      original_live = Application.get_env(:foreman_server, :debug_live_views_enabled)
      original_errors = Application.get_env(:foreman_server, :debug_errors)

      on_exit(fn ->
        if is_nil(original_live) do
          Application.delete_env(:foreman_server, :debug_live_views_enabled)
        else
          Application.put_env(:foreman_server, :debug_live_views_enabled, original_live)
        end

        if is_nil(original_errors) do
          Application.delete_env(:foreman_server, :debug_errors)
        else
          Application.put_env(:foreman_server, :debug_errors, original_errors)
        end
      end)

      Application.put_env(:foreman_server, :debug_live_views_enabled, false)
      Application.put_env(:foreman_server, :debug_errors, false)

      spec = ForemanServer.Http.Endpoint.child_spec(port: 0)
      assert {Bandit, :start_link, [options]} = spec.start
      assert options[:plug] == ForemanServer.Http.Router
    end
  end

  # ─── helpers ────────────────────────────────────────────────────────────────

  defp get_foreman_config(path) do
    @dev_config_path
    |> Config.Reader.read!(env: :dev)
    |> Keyword.get(:foreman_server, [])
    |> get_in(path)
  end

  defp get_logger_level do
    @dev_config_path
    |> Config.Reader.read!(env: :dev)
    |> Keyword.get(:logger, [])
    |> Keyword.get(:level)
  end
end
