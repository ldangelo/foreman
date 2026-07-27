defmodule ForemanServer.Application do
  @moduledoc """
  OTP application for ForemanServer.

  Starts:
  - EventStore (Postgrex-backed event log — single source of truth)
  - Aggregator supervisor (Registry + aggregate Actor children, `:permanent` restart)
  - CommandRouter (GenServer — sole append point)
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # EventStore must be started first (ProjectionStore subscribes to it).
      ForemanServer.EventStore,
      # ProjectionStore subscribes to EventStore and maintains read model.
      ForemanServer.ProjectionStore,
      # Aggregator starts the Registry and supervises Actor children.
      ForemanServer.Aggregator,
      # CommandRouter handles all append requests.
      ForemanServer.CommandRouter
    ]

    opts = [strategy: :one_for_one, name: __MODULE__]
    Supervisor.start_link(children, opts)
  end
end
