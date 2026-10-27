defmodule ForemanServer.TestSupport.ThrowawayProjectionStore do
  @moduledoc false
  # A test that must see `ForemanServer.ProjectionStore` CRASH on an event (a projector that
  # raises on a malformed payload) fires it at a throwaway store, never at the named singleton.
  # The singleton's subscribers (`Dispatcher`, `RunLifecycleReconciler`, the PR watcher, ...)
  # subscribe once, at boot, and the supervisor's restart of the store comes back with an empty
  # subscriber map: every later test that drives the live Dispatcher then waits for a run that
  # can never start (foreman-0i1s0: `beads_epic_tree_e2e_test.exs` timing out at 60 s after
  # `projection_store_phase_pr_test.exs` crashed the singleton).
  #
  # The throwaway rebuilds from the event log like the real one and takes the same
  # `{:apply_events, events, now_ms_fun}` message `ProjectionStore.apply_events/1` sends.
  import ExUnit.Assertions
  import ExUnit.CaptureLog

  @doc """
  Sends `events` to a throwaway store, asserts the call crashes it, and returns the exit reason
  (`{exception, stacktrace}`) the store died with. Must run inside a test (registers `on_exit`).
  """
  @spec crash_on_apply!([map()]) :: term()
  def crash_on_apply!(events) do
    {:ok, pid} = GenServer.start(ForemanServer.ProjectionStore, [])
    ExUnit.Callbacks.on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    ref = Process.monitor(pid)

    {exit_reason, _log} =
      with_log(fn ->
        catch_exit(GenServer.call(pid, {:apply_events, events, fn -> 1 end}))
      end)

    assert {reason, {GenServer, :call, [^pid | _]}} = exit_reason
    assert_receive {:DOWN, ^ref, :process, ^pid, _down_reason}
    reason
  end
end
