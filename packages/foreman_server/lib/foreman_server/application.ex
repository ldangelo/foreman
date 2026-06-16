defmodule ForemanServer.Application do
  @moduledoc false

  use Application

  alias ForemanServer.{EventStore, ProjectionStore, ProjectRegistry}

  @impl true
  def start(_type, _args) do
    children =
      [
        {ProjectionStore, []},
        {EventStore, []},
        {DynamicSupervisor, strategy: :one_for_one, name: ForemanServer.RunDynamicSupervisor},
        {DynamicSupervisor, strategy: :one_for_one, name: ForemanServer.ProjectDynamicSupervisor},
        {ProjectRegistry, []}
      ] ++ http_children()

    opts = [strategy: :one_for_one, name: ForemanServer.Supervisor]
    Supervisor.start_link(children, opts)
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
