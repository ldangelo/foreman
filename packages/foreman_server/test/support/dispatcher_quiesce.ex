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

  @spec suspend!() :: :ok
  def suspend! do
    pid = Process.whereis(ForemanServer.Workflow.Dispatcher)
    true = is_pid(pid)
    :ok = :sys.suspend(pid)

    # Registered before the caller's own on_exit callbacks, so it runs after
    # them (ExUnit runs on_exit in reverse order): the real BootReconciliation
    # is back in place before the queued events are processed.
    on_exit(fn ->
      if Process.alive?(pid), do: :sys.resume(pid)
    end)

    :ok
  end
end
