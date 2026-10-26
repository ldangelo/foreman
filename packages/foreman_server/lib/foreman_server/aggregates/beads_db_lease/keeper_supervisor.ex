defmodule ForemanServer.Aggregates.BeadsDbLease.KeeperSupervisor do
  @moduledoc """
  `DynamicSupervisor` that owns the `ForemanServer.Aggregates.BeadsDbLease.Keeper` of every
  `BeadsDbLease.with_lease/4` call in flight.

  It sits directly under the application supervisor, in no subtree of a process that calls
  `with_lease/4`: a keeper has to survive the death of the very process it watches, which a
  keeper linked into that process's own subtree would not. `ForemanServer.Application` starts it
  right after the `Aggregator` and before every child that can call `with_lease/4`
  (`BeadsWatcher`, the orphan janitor, boot reconciliation, the run executors), so no call finds
  it missing at boot.

  Keepers are `restart: :temporary`: a keeper that crashes is reported by OTP and not started
  again, so a systematic bug in one cannot restart-loop this supervisor into the application
  supervisor's restart intensity. The call it watched then runs unwatched, as every call did
  before keepers existed.
  """

  use DynamicSupervisor

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(_arg), do: DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)
end
