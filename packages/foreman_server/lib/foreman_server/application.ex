defmodule ForemanServer.Application do
  @moduledoc false

  use Application

  alias ForemanServer.{EventStore, Overwatch, ProjectionStore, ProjectRegistry, Repo, Scheduler}

  @impl true
  def start(_type, _args) do
    children =
      repo_children() ++
      [
        {Registry, keys: :duplicate, name: ForemanServer.InboxRegistry},
        {ProjectionStore, []},
        {Overwatch, []},
        {EventStore, []},
        {DynamicSupervisor, strategy: :one_for_one, name: ForemanServer.RunDynamicSupervisor},
        {DynamicSupervisor, strategy: :one_for_one, name: ForemanServer.ProjectDynamicSupervisor},
        {ProjectRegistry, []},
        {Scheduler, []}
      ] ++ http_children()

    opts = [strategy: :one_for_one, name: ForemanServer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp repo_children do
    if postgres_event_store?(), do: [Repo], else: []
  end

  defp postgres_event_store? do
    event_store_adapter() != :term and database_url?()
  end

  defp event_store_adapter do
    case System.get_env("FOREMAN_SERVER_EVENT_STORE_ADAPTER") do
      "term" -> :term
      "postgres" -> :postgres
      _ -> Application.get_env(:foreman_server, :event_store_adapter)
    end
  end

  defp database_url? do
    url = Application.get_env(:foreman_server, :database_url) || System.get_env("DATABASE_URL")
    is_binary(url) and url != ""
  end

  defp http_children do
    enabled? =
      Application.get_env(:foreman_server, :http_enabled, false) ||
        System.get_env("FOREMAN_SERVER_HTTP_ENABLED") == "true"

    if enabled? do
      [{ForemanServer.Http.Endpoint, []}]
    else
      []
    end
  end
end
