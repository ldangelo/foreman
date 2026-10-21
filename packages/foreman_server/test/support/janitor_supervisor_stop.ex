defmodule ForemanServer.TestSupport.JanitorSupervisorStop do
  @moduledoc """
  Deterministic teardown for `BeadsOrphanJanitorSupervisor` in tests.

  The supervisor starts its co-located `Registry` linked from `init/1`.
  `GenServer.stop/3` on the supervisor returns once the supervisor is gone,
  but the Registry shuts down asynchronously afterwards (it is a supervisor
  that terminates when its parent exits). A next test that starts the
  supervisor in that window gets `{:error, {:already_started, dying_pid}}`
  from `Registry.start_link/1`, so its children fail with
  `unknown registry: ...Registry`. `stop/1` therefore also waits (by
  monitor, no sleeping) until the Registry process is gone.
  """

  alias ForemanServer.TaskProviders.BeadsOrphanJanitorSupervisor

  @registry BeadsOrphanJanitorSupervisor.Registry

  @spec stop(pid()) :: :ok
  def stop(sup) when is_pid(sup) do
    if Process.alive?(sup) do
      try do
        # 5s, not 1s: a timeout escalates GenServer.stop to an untrappable kill.
        GenServer.stop(sup, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    await_registry_gone()
  end

  @doc "Stop whatever currently owns the supervisor's registered name, if anything."
  @spec stop_named() :: :ok
  def stop_named do
    case Process.whereis(BeadsOrphanJanitorSupervisor) do
      nil -> await_registry_gone()
      pid -> stop(pid)
    end
  end

  defp await_registry_gone do
    case Process.whereis(@registry) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          5_000 -> :ok
        end
    end
  end
end
