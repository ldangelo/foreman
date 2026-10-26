defmodule ForemanServer.Aggregates.BeadsDbLease.KeeperSupervisor do
  @moduledoc """
  `DynamicSupervisor` that owns the `ForemanServer.Aggregates.BeadsDbLease.Keeper` of every
  `BeadsDbLease.with_lease/4` call in flight.

  It sits directly under the application supervisor, in no subtree of a process that calls
  `with_lease/4`: a keeper has to survive the death of the very process it watches, which a
  keeper linked into that process's own subtree would not. `ForemanServer.Application` starts it
  right after the `Aggregator` (and the `KeeperRegistry` that names the keepers) and before every
  child that can call `with_lease/4` (`BeadsWatcher`, the orphan janitor, boot reconciliation, the
  run executors), so no call finds it missing at boot.

  Keepers are `restart: :transient`: one that ends abnormally while its caller lives is started
  again from the same arguments and monitors the caller again; a normal end is final. Restarts
  are bounded twice. A keeper that keeps crashing is not restarted after five restarts (it
  counts them itself, across restarts), and this supervisor's own intensity is set far above what
  those bounded loops can add up to, so even a crash that hits every keeper at once cannot
  exhaust it and take the keepers of all other calls down with it.
  """

  use DynamicSupervisor

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(_arg), do: DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok),
    do: DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 1_000, max_seconds: 5)
end
