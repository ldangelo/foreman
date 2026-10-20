defmodule ForemanServer.TestSupport.DispatcherRestart do
  @moduledoc false
  # Test files that keep the app-level `ForemanServer.Workflow.Dispatcher` out of the way
  # (terminated, or `:sys.suspend/1`ed, so a `TaskApproved`/`TaskDispatched` projection cannot
  # start a real run mid-test) put it back with `restart!/0` in `on_exit`. A restart that
  # returns early is a cross-test writer.
  #
  # `Dispatcher.init/1` calls `ProjectionStore.subscribe(replay_existing: true)`, which sends the
  # ENTIRE event log, one `{:projection_event, event}` per event, into the new Dispatcher's
  # mailbox before the call returns; the Dispatcher then handles that backlog one message at a
  # time. `Supervisor.restart_child/2` returns as soon as `init/1` does, i.e. with the whole
  # backlog still queued, so the Dispatcher works through it while the next test runs. Each
  # terminal run event in the backlog releases that run's slot (`run_slots.release`), and every
  # task the projection still shows is acted on again: a `TaskDispatched` task still
  # `in_progress` is re-admitted through `RunAdmission.start/2` (`run_slots.acquire`), a
  # `TaskApproved` task still `ready` is re-dispatched. That is a stream of writes to the real,
  # process-wide `run_slots:global` aggregate for `run-<64 hex>` ids the next test never
  # created, starting after the restart returned: a test that reads that stream meanwhile (the
  # `RunLifecycleReconciler` backstop sweep) sees holders that are not its own.
  #
  # `restart!/0` therefore resets the projection first and returns only once the new Dispatcher
  # has finished what its restart caused:
  #
  #   * The replay acts on whatever the projection still shows, so the tasks of the test that
  #     just ended are dropped from it (subscribers kept, as `command_gateway_test.exs` already
  #     does by hand). Otherwise the re-admission above also starts a real `RunExecutor`, whose
  #     kickoff no barrier on the Dispatcher can wait for. With nothing in the projection those
  #     handlers do nothing, so what is left of the replay is the slot release of each terminal
  #     run (and `RunControl` bookkeeping).
  #   * The replayed events are all queued before `init/1` returns, so a system message sent
  #     after `restart_child/2` is dequeued behind every one of them. `:sys.suspend/2` is such a
  #     message: it is answered only after the replay has been handled.
  #   * The handlers do their work inline, in the Dispatcher process (`RunAdmission.start/2`, the
  #     slot and lease releases and the `task.dispatch` command are synchronous calls, not
  #     tasks), so a message whose handler has returned has finished its `run_slots:global`
  #     writes, compensating release included.
  #   * A handler's own commands come back as events: `CommandRouter` applies each commit to
  #     `ProjectionStore`, which broadcasts it to the Dispatcher before the command returns (a
  #     replayed `RunCompleted` releases a held slot, and the resulting `RunSlotReleased` is
  #     queued behind the barrier above). A suspended Dispatcher handles nothing, so its
  #     `message_queue_len` is exactly that backlog: 0 means nothing is queued and no handler is
  #     mid-flight, anything else means resume it and go round again.
  #
  # The wait is bounded: a Dispatcher that keeps queueing work for itself fails the restart
  # instead of leaking that work into the next test.
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @app_supervisor ForemanServer.Application
  @dispatcher ForemanServer.Workflow.Dispatcher
  @drain_timeout_ms 30_000

  @spec restart!() :: :ok
  def restart! do
    :ok = Supervisor.terminate_child(@app_supervisor, @dispatcher)
    :ok = ProjectionStoreReset.reset!(keep_subscribers: true)
    {:ok, dispatcher} = Supervisor.restart_child(@app_supervisor, @dispatcher)

    drain!(dispatcher, System.monotonic_time(:millisecond) + @drain_timeout_ms)
  end

  # `Dispatcher.init/1` swallows a failed `ProjectionStore.subscribe/1` and schedules
  # `:retry_subscribe` (state `%{subscriber: :retrying}`): the replay would then arrive AFTER an
  # empty mailbox looked drained. So a Dispatcher that is still retrying is not drained yet.
  defp drain!(dispatcher, deadline_ms) do
    timeout_ms = deadline_ms - System.monotonic_time(:millisecond)

    if timeout_ms <= 0 do
      raise "#{inspect(@dispatcher)} was still handling events #{@drain_timeout_ms}ms after " <>
              "its restart: it keeps queueing work for itself or never subscribed"
    end

    case suspend_and_count(dispatcher, timeout_ms) do
      {:retrying, _queued} ->
        Process.sleep(10)
        drain!(dispatcher, deadline_ms)

      {:subscribed, queued} when queued > 0 ->
        drain!(dispatcher, deadline_ms)

      {:subscribed, 0} ->
        :ok
    end
  end

  # `:sys.suspend/2` timing out does not cancel the request: it would still suspend the
  # Dispatcher later, leaving it frozen for the next test. On that failure queue a resume behind
  # it (so the Dispatcher ends up running) and fail the restart. Once the suspend has succeeded,
  # the resume is unconditional (`after`): nothing below may leave the Dispatcher frozen.
  defp suspend_and_count(dispatcher, timeout_ms) do
    try do
      :ok = :sys.suspend(dispatcher, timeout_ms)
    catch
      :exit, reason ->
        :ok = :sys.resume(dispatcher, @drain_timeout_ms)

        raise "#{inspect(@dispatcher)} did not reach its suspend barrier within #{timeout_ms}ms: " <>
                inspect(reason)
    end

    try do
      {:message_queue_len, queued} = Process.info(dispatcher, :message_queue_len)
      %{} = state = :sys.get_state(dispatcher)

      {if(Map.get(state, :subscriber) == :retrying, do: :retrying, else: :subscribed), queued}
    after
      :ok = :sys.resume(dispatcher, @drain_timeout_ms)
    end
  end
end
