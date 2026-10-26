defmodule ForemanServer.TestSupport.LeaseKeepers do
  @moduledoc """
  Reads the `BeadsDbLease.Keeper`s of the `with_lease/4` calls a process is in.

  A test names the process it cares about, so it never depends on the keepers other tests left
  running: a keeper of a killed caller finishes its cleanup after that test is already over.
  """

  alias ForemanServer.Aggregates.BeadsDbLease.KeeperSupervisor

  @doc """
  The keepers watching `caller`, one per `with_lease/4` call it is in. Empty while
  `KeeperSupervisor` is not running: nothing keeps any call then.
  """
  @spec for_caller(pid()) :: [pid()]
  def for_caller(caller) when is_pid(caller) do
    case Process.whereis(KeeperSupervisor) do
      nil ->
        []

      supervisor ->
        for {_id, keeper, _type, _modules} <- DynamicSupervisor.which_children(supervisor),
            is_pid(keeper),
            watches?(keeper, caller),
            do: keeper
    end
  end

  defp watches?(keeper, caller) do
    match?(%{caller: ^caller}, :sys.get_state(keeper))
  catch
    # It finished between listing and asking.
    :exit, _reason -> false
  end
end
