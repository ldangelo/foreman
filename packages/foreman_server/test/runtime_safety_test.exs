defmodule ForemanServer.RuntimeSafetyTest do
  use ExUnit.Case

  setup do
    original_env = %{
      "FOREMAN_SERVER_HTTP_ENABLED" => System.get_env("FOREMAN_SERVER_HTTP_ENABLED"),
      "FOREMAN_SERVER_HTTP_PORT" => System.get_env("FOREMAN_SERVER_HTTP_PORT"),
      "FOREMAN_SERVER_EVENT_LOG" => System.get_env("FOREMAN_SERVER_EVENT_LOG"),
      "FOREMAN_SERVER_PROJECT_STORE" => System.get_env("FOREMAN_SERVER_PROJECT_STORE"),
      "FOREMAN_SERVER_EVENT_STORE_ADAPTER" =>
        System.get_env("FOREMAN_SERVER_EVENT_STORE_ADAPTER"),
      "DATABASE_URL" => System.get_env("DATABASE_URL"),
      "FOREMAN_ALLOW_TEST_PORT_COLLISION" => System.get_env("FOREMAN_ALLOW_TEST_PORT_COLLISION"),
      "FOREMAN_ALLOW_TEST_PERSISTENT_STORAGE" =>
        System.get_env("FOREMAN_ALLOW_TEST_PERSISTENT_STORAGE")
    }

    original_app = %{
      http_enabled: Application.get_env(:foreman_server, :http_enabled),
      http_port: Application.get_env(:foreman_server, :http_port),
      event_log_path: Application.get_env(:foreman_server, :event_log_path),
      project_store_path: Application.get_env(:foreman_server, :project_store_path)
    }

    on_exit(fn ->
      Enum.each(original_env, fn {key, value} ->
        if is_nil(value), do: System.delete_env(key), else: System.put_env(key, value)
      end)

      Enum.each(original_app, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:foreman_server, key),
          else: Application.put_env(:foreman_server, key, value)
      end)
    end)

    :ok
  end

  test "test runtime uses isolated default HTTP port" do
    System.delete_env("FOREMAN_SERVER_HTTP_PORT")
    Application.delete_env(:foreman_server, :http_port)

    assert ForemanServer.RuntimeInfo.default_http_port() == 14766
    assert ForemanServer.RuntimeInfo.http_port() == 14766
  end

  test "invalid HTTP port env falls back instead of crashing" do
    System.put_env("FOREMAN_SERVER_HTTP_PORT", "not-a-port")
    Application.delete_env(:foreman_server, :http_port)

    assert ForemanServer.RuntimeInfo.http_port() == 14766
  end

  test "postgres runtime identity distinguishes storage roles" do
    System.put_env("DATABASE_URL", "postgres://localhost/foreman_test")
    System.put_env("FOREMAN_SERVER_EVENT_STORE_ADAPTER", "postgres")

    identity = ForemanServer.RuntimeInfo.identity()

    assert identity.event_store.adapter == "postgres"
    assert identity.event_store.table == "foreman_events"
    assert identity.projection_store.adapter == "postgres"
    assert "foreman_task_projections" in identity.projection_store.tables
    assert identity.project_config_store.adapter == "term"
  end

  test "postgres event store requires DATABASE_URL" do
    System.delete_env("DATABASE_URL")
    System.put_env("FOREMAN_SERVER_EVENT_STORE_ADAPTER", "postgres")

    assert_raise ArgumentError, ~r/postgres event store but no DATABASE_URL/, fn ->
      ForemanServer.RuntimeSafety.validate!()
    end
  end

  test "refuses MIX_ENV=test on the user-facing HTTP port" do
    tmp_dir = System.tmp_dir!()
    Application.put_env(:foreman_server, :http_enabled, true)
    Application.put_env(:foreman_server, :http_port, 4766)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))
    Application.put_env(:foreman_server, :project_store_path, Path.join(tmp_dir, "projects.term"))

    assert_raise ArgumentError, ~r/MIX_ENV=test on user HTTP port 4766/, fn ->
      ForemanServer.RuntimeSafety.validate!()
    end
  end

  test "refuses MIX_ENV=test with persistent repo storage" do
    Application.put_env(:foreman_server, :http_enabled, true)
    Application.put_env(:foreman_server, :http_port, 14766)

    Application.put_env(
      :foreman_server,
      :event_log_path,
      Path.expand("var/foreman_server/events.term.log")
    )

    Application.put_env(
      :foreman_server,
      :project_store_path,
      Path.join(System.tmp_dir!(), "projects.term")
    )

    assert_raise ArgumentError, ~r/non-temp event log path/, fn ->
      ForemanServer.RuntimeSafety.validate!()
    end
  end

  test "explicit override allows test runtime collision only when requested" do
    Application.put_env(:foreman_server, :http_enabled, true)
    Application.put_env(:foreman_server, :http_port, 4766)

    Application.put_env(
      :foreman_server,
      :event_log_path,
      Path.expand("var/foreman_server/events.term.log")
    )

    Application.put_env(
      :foreman_server,
      :project_store_path,
      Path.expand("var/foreman_server/projects.term")
    )

    System.put_env("FOREMAN_ALLOW_TEST_PORT_COLLISION", "1")
    System.put_env("FOREMAN_ALLOW_TEST_PERSISTENT_STORAGE", "1")

    assert :ok = ForemanServer.RuntimeSafety.validate!()
  end
end
