defmodule ForemanServer.Application do
  @moduledoc false

  use Application

  alias ForemanServer.{EventStore, ProjectionStore, ProjectRegistry}

  @impl true
  def start(_type, _args) do
    children = [
      {ProjectionStore, []},
      {EventStore, []},
      {DynamicSupervisor, strategy: :one_for_one, name: ForemanServer.ProjectDynamicSupervisor},
      {ProjectRegistry, []}
    ]

    opts = [strategy: :one_for_one, name: ForemanServer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
