defmodule ForemanServer.RuntimeInfo do
  @moduledoc "Runtime identity helpers for storage, ports, and operator diagnostics."

  @user_http_port 4766
  @test_http_port 14766

  @spec identity() :: map()
  def identity do
    adapter = event_store_adapter()

    %{
      mix_env: mix_env(),
      http: %{
        enabled: http_enabled?(),
        port: http_port()
      },
      event_store: %{
        adapter: Atom.to_string(adapter),
        path: if(adapter == :term, do: event_log_path(), else: nil),
        table: if(adapter == :postgres, do: "foreman_events", else: nil)
      },
      projection_store: %{
        adapter: Atom.to_string(projection_store_adapter()),
        tables: projection_store_tables()
      },
      project_config_store: %{
        adapter: "term",
        path: project_store_path(required?: true)
      },
      project_store: %{
        adapter: "term",
        path: project_store_path(required?: true)
      }
    }
  end

  @spec mix_env() :: String.t()
  def mix_env do
    System.get_env("MIX_ENV") ||
      if Code.ensure_loaded?(Mix) do
        Mix.env() |> Atom.to_string()
      else
        "prod"
      end
  end

  @spec http_enabled?() :: boolean()
  def http_enabled? do
    Application.get_env(:foreman_server, :http_enabled, false) ||
      System.get_env("FOREMAN_SERVER_HTTP_ENABLED") == "true"
  end

  @spec http_port() :: integer()
  def http_port do
    parse_port(System.get_env("FOREMAN_SERVER_HTTP_PORT")) ||
      Application.get_env(:foreman_server, :http_port) ||
      default_http_port()
  end

  @spec default_http_port() :: integer()
  def default_http_port do
    if mix_env() == "test", do: @test_http_port, else: @user_http_port
  end

  @spec event_store_adapter() :: :term | :postgres
  def event_store_adapter do
    case System.get_env("FOREMAN_SERVER_EVENT_STORE_ADAPTER") do
      "term" ->
        :term

      "postgres" ->
        :postgres

      _ ->
        Application.get_env(:foreman_server, :event_store_adapter) ||
          default_event_store_adapter()
    end
  end

  @spec projection_store_adapter() :: :memory | :postgres
  def projection_store_adapter do
    if event_store_adapter() == :postgres and database_url?(), do: :postgres, else: :memory
  end

  @spec projection_store_tables() :: [String.t()] | nil
  def projection_store_tables do
    if projection_store_adapter() == :postgres do
      [
        "foreman_project_projections",
        "foreman_task_projections",
        "foreman_run_projections",
        "foreman_inbox_message_projections",
        "foreman_projection_checkpoints"
      ]
    end
  end

  @spec event_log_path() :: String.t()
  def event_log_path do
    Application.get_env(:foreman_server, :event_log_path) ||
      System.get_env("FOREMAN_SERVER_EVENT_LOG") ||
      default_event_log_path()
  end

  @spec project_store_path(keyword()) :: String.t() | nil
  def project_store_path(opts \\ []) do
    required? = Keyword.get(opts, :required?, false)

    Application.get_env(:foreman_server, :project_store_path) ||
      System.get_env("FOREMAN_SERVER_PROJECT_STORE") ||
      if(required?, do: default_project_store_path(), else: nil)
  end

  @spec database_url?() :: boolean()
  def database_url? do
    url = Application.get_env(:foreman_server, :database_url) || System.get_env("DATABASE_URL")
    is_binary(url) and url != ""
  end

  @spec github_webhook_secret() :: String.t() | nil
  def github_webhook_secret do
    case System.get_env("FOREMAN_GITHUB_WEBHOOK_SECRET") ||
           Application.get_env(:foreman_server, :github_webhook_secret) do
      secret when is_binary(secret) and secret != "" -> secret
      _ -> nil
    end
  end

  defp default_event_store_adapter do
    if database_url?(), do: :postgres, else: :term
  end

  defp default_event_log_path do
    if mix_env() == "test" do
      Path.join(test_tmp_root(), "events.term.log")
    else
      Path.expand("var/foreman_server/events.term.log")
    end
  end

  defp default_project_store_path do
    if mix_env() == "test" do
      Path.join(test_tmp_root(), "projects.term")
    else
      Path.expand("var/foreman_server/projects.term")
    end
  end

  defp test_tmp_root do
    Path.expand("../../../tmp/test", __DIR__)
  end

  defp parse_port(nil), do: nil

  defp parse_port(value) do
    case Integer.parse(value) do
      {port, ""} when port >= 0 and port <= 65_535 -> port
      _ -> nil
    end
  end

  @doc """
  Finite, configurable timeout (ms) for the projection rebuild path:
  EventStore.start_link/1 init, EventStore.rebuild_projections/0
  GenServer.call/3 (used by POST /rebuild_projections), and
  ProjectionStore.Postgres.replace_all/1 Repo.transaction/3.

  Resolution order:
  1. Env var FOREMAN_SERVER_PROJECTION_REBUILD_TIMEOUT_MS, if
     present and a positive integer.
  2. App config :foreman_server, :projection_rebuild_timeout_ms
     (set by config/config.exs), if positive.
  3. Default 600_000 ms (10 minutes).

  Reading timing is per-call. The EventStore.start_link/1 init
  timeout is captured when the supervisor spawns the GenServer, so
  a new env value affects the next start, not a running process.
  The HTTP-triggered rebuild_projections/0 and Repo.transaction/3
  paths read at request time, so the next request after an env change
  picks up the new value without restart.

  Invalid values (non-integer strings, integers <= 0, or env values
  with trailing characters like "600000ms") fall back to step 2,
  then step 3.
  """
  @spec projection_rebuild_timeout_ms() :: pos_integer()
  def projection_rebuild_timeout_ms do
    parse_pos_int(System.get_env("FOREMAN_SERVER_PROJECTION_REBUILD_TIMEOUT_MS")) ||
      parse_pos_int(Application.get_env(:foreman_server, :projection_rebuild_timeout_ms)) ||
      600_000
  end

  defp parse_pos_int(nil), do: nil

  defp parse_pos_int(value) when is_integer(value) and value > 0, do: value

  defp parse_pos_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_pos_int(_), do: nil
end
