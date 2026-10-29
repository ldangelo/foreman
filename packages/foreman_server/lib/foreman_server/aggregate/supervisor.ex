defmodule ForemanServer.Aggregator do
  @moduledoc """
  Supervisor that manages aggregate `Actor` children.

  Uses `restart: :permanent` — every actor is critical and must be restarted
  immediately on exit. Children are started on-demand via `start_aggregate/3`.

  The `ForemanServer.AggregateRegistry` the actors register in is a sibling of this supervisor,
  not a child: `ForemanServer.Application` starts it just ahead of this one. The restart budget
  below (100 in 5 s) can be exhausted by a storm of actor crashes, and the Aggregator then dies
  with every actor; the application supervisor starts it again empty and it refills on demand. A
  registry owned by the Aggregator died with it, and every `Registry.lookup/2` raised
  `unknown registry` until the Aggregator was back.
  """

  use Supervisor

  @spec start_link(init_arg :: term()) :: Supervisor.on_start()
  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # No static children: actors are added on demand by `start_aggregate/3`, and the registry
    # they register in is the application's (see the moduledoc).
    #
    # Explicit intensity: tests rapidly kill multiple actors in succession
    # (e.g. AC1.3 kills 5 types, AC1.6 kills 1). Default of 3/5s is exceeded.
    Supervisor.init([],
      strategy: :one_for_one,
      max_restarts: 100,
      max_seconds: 5
    )
  end

  @doc """
  Start (or look up) a supervised aggregate actor for aggregate_id.

  `opts` go to `ForemanServer.Aggregate.Actor.start_link/3` (`:router`). A running actor cannot
  take them: asked for with options, it is `{:error, {:already_started, pid}}` rather than a
  silently different actor.
  """
  @spec start_aggregate(module, aggregate_id :: String.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_aggregate(aggregate_module, aggregate_id, opts \\ []) do
    # Check if already running first (avoids Supervisor.start_child overhead for the common case).
    case Registry.lookup(ForemanServer.AggregateRegistry, aggregate_id) do
      [{pid, _}] when opts == [] -> {:ok, pid}
      [{pid, _}] -> {:error, {:already_started, pid}}
      [] -> start_aggregate_child(aggregate_module, aggregate_id, opts)
    end
  end

  # Start the Actor as a dynamic child of this supervisor.
  # The Aggregator's restart strategy (:permanent) applies to all children.
  defp start_aggregate_child(aggregate_module, aggregate_id, opts) do
    child_spec = %{
      id: aggregate_id,
      start: {ForemanServer.Aggregate.Actor, :start_link, [aggregate_module, aggregate_id, opts]},
      restart: :permanent,
      type: :worker
    }

    case Supervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end
end
