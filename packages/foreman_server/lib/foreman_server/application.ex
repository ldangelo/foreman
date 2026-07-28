defmodule ForemanServer.Application do
  @moduledoc """
  OTP application for ForemanServer.

  Starts:
  - CommandedApplication (Commanded.EventStore adapter → owns EventStore)
  - Aggregator supervisor (Registry + aggregate Actor children, :permanent restart)
  - CommandRouter (GenServer — sole append point)
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Commanded application must start before CommandRouter uses it.
      # Its adapter child owns and starts ForemanServer.EventStore.
      ForemanServer.CommandedApplication,
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
