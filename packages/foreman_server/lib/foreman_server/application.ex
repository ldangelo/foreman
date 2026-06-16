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
        {DynamicSupervisor, strategy: :one_for_one, name: ForemanServer.ProjectDynamicSupervisor},
        {ProjectRegistry, []}
      ] ++ http_children()

    opts = [strategy: :one_for_one, name: ForemanServer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp http_children do
    if Application.get_env(:foreman_server, :http_enabled, false) do
      [{ForemanServer.Http.Endpoint, []}]
    else
      []
    end
  end
end
