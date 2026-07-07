defmodule ForemanServer.Application do
  @moduledoc false

  use Application

  alias ForemanServer.{
    EventStore,
    Overwatch,
    ProjectionStore,
    ProjectRegistry,
    Repo,
    RuntimeSafety,
    Scheduler
  }

  @impl true
  def start(_type, _args) do
    RuntimeSafety.validate!()

    children =
      repo_children() ++
        [
          {Registry, keys: :duplicate, name: ForemanServer.InboxRegistry},
          {ProjectionStore, []},
          {Overwatch, []},
          {EventStore, []},
          {DynamicSupervisor, strategy: :one_for_one, name: ForemanServer.RunDynamicSupervisor},
          {DynamicSupervisor,
           strategy: :one_for_one, name: ForemanServer.ProjectDynamicSupervisor},
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
    ForemanServer.RuntimeInfo.event_store_adapter() == :postgres
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
