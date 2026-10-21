defmodule ForemanServer.DispatcherQuiesce do
  @moduledoc """
  Test helper that freezes the application's real singleton
  `ForemanServer.Workflow.Dispatcher` for the duration of one test.

  Tests that swap a forwarder in for the registered name
  `ForemanServer.Workflow.BootReconciliation` (or mock
  `CommandGateway.dispatch_system`) and then call
  `Dispatcher.handle_info/2` directly observe the dispatcher's effects through
  a process-global channel. The real Dispatcher stays subscribed to
  `ProjectionStore` and reacts to every terminal run event emitted by any other
  test, so its `run_terminated` casts and slot-release dispatches would also
  reach that channel, and `refute_receive` with wildcard ids would fail on
  somebody else's event.

  `suspend!/0` must be called before the name swap / mock is installed:
  `:sys.suspend/1` returns only after the Dispatcher finished any message it was
  handling, so nothing it did earlier can reach the swapped channel. Events
  queue in its mailbox while suspended and are processed (against the restored
  real `BootReconciliation`) when the test exits.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @default_timeout_ms 30_000

  @doc """
  Suspends the Dispatcher (or `opts[:pid]`) and guarantees it is resumed when
  the test exits.

  The resume callback is registered BEFORE the suspend request is sent.
  `:sys.suspend/2` exits on timeout (e.g. the target is stuck in a long
  message) but its request stays queued in the target's mailbox and suspends
  it later; had the callback been registered after the call, that late
  suspension would never be undone. Resuming an unsuspended or dead process is
  harmless, so the callback is safe whether or not the suspend took effect.
  Callbacks run in reverse registration order, so this one runs after the
  caller's own `on_exit` callbacks and the real `BootReconciliation` is back in
  place before the queued events are processed.
  """
  @spec suspend!(pid: pid(), timeout: timeout()) :: :ok
  def suspend!(opts \\ []) do
    pid =
      Keyword.get_lazy(opts, :pid, fn -> Process.whereis(ForemanServer.Workflow.Dispatcher) end)

    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    true = is_pid(pid)

    on_exit(fn -> resume(pid) end)

    :ok = :sys.suspend(pid, timeout)
  end

  defp resume(pid) do
    :sys.resume(pid, @default_timeout_ms)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
    :exit, {:killed, _} -> :ok
  end
end
