defmodule ForemanServer.TestSupport.RunDrain do
  @moduledoc false
  # Quiesces the run machinery a previous test left behind, so nothing it
  # does can land on the next test's freshly reset store.
  #
  # A test that approves a task through the real `Dispatcher` starts a real
  # `RunExecutor` under `RunSupervisor`. That executor fails (or completes) on
  # its own schedule - typically a few ms after the test ended - and its
  # terminal event then fans out through `Dispatcher` (`run_slots.release`) and
  # `BootReconciliation` (`task.run_terminated`). If the next test has already
  # reset the projection store and `run_slots:global`, the executor finds its
  # project gone (`:project_not_found`), the slot release races the reset's
  # actor kill (`run_slots.release ... exited {:killed, ...}`), and
  # `TaskRunTerminated` arrives for a task the store no longer knows.
  #
  # `drain!/1` stops every executor under `RunSupervisor` (synchronously) and
  # then flushes the Dispatcher -> BootReconciliation -> Dispatcher mailboxes, so
  # events those executors already emitted are fully handled before the caller
  # resets anything.

  @default_barriers [ForemanServer.Workflow.Dispatcher, ForemanServer.Workflow.BootReconciliation]
  @barrier_timeout_ms 5_000

  @spec drain!(keyword()) :: :ok
  def drain!(opts \\ []) do
    barriers = Keyword.get(opts, :barrier, @default_barriers)

    stop_executors()

    # Dispatcher may cast to BootReconciliation, whose dispatches the
    # Dispatcher can observe again, hence the second pass.
    flush(barriers)
    flush(barriers)
    :ok
  end

  defp stop_executors do
    case Process.whereis(ForemanServer.Workflow.RunSupervisor) do
      nil ->
        :ok

      sup ->
        for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(sup), is_pid(pid) do
          # `terminate_child/2` returns once the child is down.
          _ = DynamicSupervisor.terminate_child(sup, pid)
        end

        :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp flush(names) do
    for name <- names, pid = Process.whereis(name), is_pid(pid) do
      try do
        # Answered only after every message already in the mailbox (also works
        # while the process is suspended by `DispatcherQuiesce`).
        :sys.get_state(pid, @barrier_timeout_ms)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end
end
