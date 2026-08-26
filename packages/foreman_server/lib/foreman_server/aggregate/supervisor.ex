defmodule ForemanServer.Aggregator do
  @moduledoc """
  Supervisor that manages aggregate `Actor` children.

  Uses `restart: :permanent` — every actor is critical and must be restarted
  immediately on exit. Children are started on-demand via `start_aggregate/2`.
  """

  use Supervisor

  @spec start_link(init_arg :: term()) :: Supervisor.on_start()
  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      # Registry must be started before any actor tries to register.
      {Registry, keys: :unique, name: ForemanServer.AggregateRegistry}
    ]

    # Explicit intensity: tests rapidly kill multiple actors in succession
    # (e.g. AC1.3 kills 5 types, AC1.6 kills 1). Default of 3/5s is exceeded.
    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: 100,
      max_seconds: 5
    )
  end

  @doc "Start (or look up) a supervised aggregate actor for aggregate_id."
  @spec start_aggregate(module, aggregate_id :: String.t()) :: {:ok, pid()}
  def start_aggregate(aggregate_module, aggregate_id) do
    # Check if already running first (avoids Supervisor.start_child overhead for the common case).
    case Registry.lookup(ForemanServer.AggregateRegistry, aggregate_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> start_aggregate_child(aggregate_module, aggregate_id)
    end
  end

  # Start the Actor as a dynamic child of this supervisor.
  # The Aggregator's restart strategy (:permanent) applies to all children.
  defp start_aggregate_child(aggregate_module, aggregate_id) do
    child_spec = %{
      id: aggregate_id,
      start: {ForemanServer.Aggregate.Actor, :start_link, [aggregate_module, aggregate_id]},
      restart: :permanent,
      type: :worker
    }

    case Supervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end
end
