defmodule ForemanServer.TestSupport.ThrowawayProjectionStore do
  @moduledoc false
  # A test that must see `ForemanServer.ProjectionStore` CRASH on an event (a projector that
  # raises on a malformed payload) fires it at a throwaway store, never at the named singleton.
  # Crashing the singleton restarts every projection (and replays the log to `replay_existing`
  # subscribers); the restart path itself is covered by `projection_store_restart_test.exs`
  # (foreman-m75e9: the restarted store re-adopts its subscribers via `SubscriberLedger`).
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
