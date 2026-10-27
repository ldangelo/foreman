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
  # The executor need not exist yet when the drain starts. A test that ends right after
  # approving a task leaves the Dispatcher still handling `TaskDispatched`
  # (`RunAdmission.start/2` is several aggregate round trips; a Dispatcher that was just
  # restarted is behind its whole replay of the event log), and it is the Dispatcher that
  # starts the executor, when it gets to it. Stopping the executors first and flushing the
  # Dispatcher afterwards lets that very flush start the executor the stop had just missed:
  # it outlives the drain and the reset, finds its project gone and, 30-60 ms later, emits
  # `PhaseStarted`, `PhaseFailed`, `TaskExecutionFailed` and `RunSlotReleased`, none of which
  # names a project, into whichever test runs then (foreman-nix1u: every workspace view
  # refreshes on an event that names no project).
  #
  # So `drain!/1` works in rounds. A round flushes the Dispatcher -> BootReconciliation ->
  # Dispatcher mailboxes (what is queued there runs to the end, and may start executors),
  # then stops every executor under `RunSupervisor` (synchronously). A round that stopped
  # something goes round again: the events those executors emitted on the way out are queued
  # behind the barriers, and handling them may start more. The drain returns after the first
  # round that found nothing to stop: no executor is running and nothing queued can start one.

  @default_barriers [ForemanServer.Workflow.Dispatcher, ForemanServer.Workflow.BootReconciliation]
  @barrier_timeout_ms 5_000
  # A drain that still finds executors after this many rounds is draining a Dispatcher that
  # keeps starting runs for itself: fail instead of leaking them into the next test.
  @max_rounds 10

  @spec drain!(keyword()) :: :ok
  def drain!(opts \\ []) do
    drain_rounds(Keyword.get(opts, :barrier, @default_barriers), @max_rounds)
  end

  defp drain_rounds(_barriers, 0) do
    raise "RunDrain.drain!/1: executors were still being started after #{@max_rounds} rounds " <>
            "of flush-and-stop; the barrier processes keep starting runs for themselves"
  end

  defp drain_rounds(barriers, rounds_left) do
    # Dispatcher may cast to BootReconciliation, whose dispatches the
    # Dispatcher can observe again, hence the second pass.
    flush(barriers)
    flush(barriers)

    case stop_executors() do
      0 -> :ok
      _stopped -> drain_rounds(barriers, rounds_left - 1)
    end
  end

  # The number of executors stopped.
  defp stop_executors do
    case Process.whereis(ForemanServer.Workflow.RunSupervisor) do
      nil ->
        0

      sup ->
        executors =
          for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(sup),
              is_pid(pid),
              do: pid

        # `terminate_child/2` returns once the child is down.
        Enum.each(executors, &DynamicSupervisor.terminate_child(sup, &1))
        length(executors)
    end
  catch
    :exit, _ -> 0
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
