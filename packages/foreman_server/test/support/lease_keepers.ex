defmodule ForemanServer.TestSupport.LeaseKeepers do
  @moduledoc """
  Reads the `BeadsDbLease.Keeper`s of the `with_lease/4` calls a process is in.

  A test names the process it cares about, so it never depends on the keepers other tests left
  running: a keeper of a killed caller finishes its cleanup after that test is already over.
  """

  alias ForemanServer.Aggregates.BeadsDbLease.{KeeperRegistry, KeeperSupervisor}

  @doc """
  The keepers watching `caller`, one per `with_lease/4` call it is in. Empty while
  `KeeperSupervisor` is not running: nothing keeps any call then.
  """
  @spec for_caller(pid()) :: [pid()]
  def for_caller(caller) when is_pid(caller) do
    case Process.whereis(KeeperSupervisor) do
      nil -> []
      _supervisor -> registered_for(caller)
    end
  end

  # Read from the registry each keeper registers its caller in, never by asking the keeper: a
  # keeper blocked in a command to a suspended actor does not answer `:sys.get_state/1` until
  # that command times out. An entry outlives its keeper by a moment, hence the liveness check.
  defp registered_for(caller) do
    KeeperRegistry
    |> Registry.select([{{{:call, :_, :_, :_}, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {keeper, watched} -> watched == caller and Process.alive?(keeper) end)
    |> Enum.map(fn {keeper, _watched} -> keeper end)
  end
end
