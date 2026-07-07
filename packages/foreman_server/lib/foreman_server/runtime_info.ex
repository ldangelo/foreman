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
      project_store: %{
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
end
