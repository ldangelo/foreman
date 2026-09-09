defmodule ForemanServer.TestSupport.RunSlotsReset do
  @moduledoc false
  # The `run_slots:global` aggregate is a process-wide singleton (its
  # `aggregate_id` is hardcoded in `RunAdmission.acquire_slot/2` and the
  # dispatcher/release paths). Tests that exercise `RunAdmission.start/3`
  # append `RunSlotAcquired` events to its event stream and mutate the
  # shared actor's in-memory `holders` / `waiters` state. Without a
  # per-test reset, one file's holders persist into the next file's
  # `setup` (and the next example within a file) and downstream
  # admissions return `:slot_queued`.
  #
  # `reset!/0` mirrors `run_executor_test.exs`'s
  # `init_run_slots_capacity/0`: hard-delete the stream, kill the actor
  # (so the next lookup re-replays the now-empty stream), then reset the
  # projection store's slot view via the suite-wide helper that seeds
  # every key the production `initial_state/0` defines, passing
  # `keep_subscribers: true` so a live Dispatcher/RunLifecycleReconciler
  # subscription survives the reset (see foreman-test-isolation root
  # cause #4 — the default clobbers subscribers, which silently kills
  # the dispatch chain for tests exercising the wired Dispatcher).
  # Hard delete requires `enable_hard_deletes: true` in
  # `ForemanServer.EventStore` config, which `config/test.exs` sets.
  @spec reset!() :: :ok
  def reset! do
    stream = "run_slots:global"

    hard_delete_with_retry(stream, 3)

    case Registry.lookup(ForemanServer.AggregateRegistry, stream) do
      [{pid, _}] when is_pid(pid) ->
        Process.exit(pid, :kill)

      _ ->
        :ok
    end

    # Give the Aggregator supervisor time to restart the actor and
    # register the new pid under the same aggregate_id before the next
    # dispatch. Without this, `Aggregator.start_aggregate/2` can return
    # the stale dead pid and the subsequent `GenServer.call` exits.
    Process.sleep(20)

    ForemanServer.TestSupport.ProjectionStoreReset.reset!(keep_subscribers: true)
    :ok
  end

  # `EventStore.delete_stream/3` normally returns `:ok | {:ok, _} |
  # {:error, :stream_not_found} | {:error, :not_supported}`. Under full-suite
  # concurrent load a background writer (e.g. `RunLifecycleReconciler` or
  # another test's in-flight `run_slots.release` dispatch) can still be
  # inserting `stream_events` rows for this same stream at the exact moment
  # the hard delete runs, which Postgres reports as a
  # `stream_events_stream_id_fkey` foreign-key violation rather than any of
  # the shapes above. That is a transient race, not a real error: retry a
  # bounded number of times with a short backoff so the concurrent writer's
  # transaction has time to settle, then give up quietly (the next test's
  # own reset — or this same reset on the next attempt — gets another
  # chance; raising here would crash the test's `setup` instead of the
  # test itself).
  defp hard_delete_with_retry(_stream, 0), do: :ok

  defp hard_delete_with_retry(stream, attempts_left) do
    case ForemanServer.EventStore.delete_stream(stream, :any_version, :hard) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, :stream_not_found} -> :ok
      {:error, :not_supported} -> :ok
      {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} ->
        Process.sleep(20)
        hard_delete_with_retry(stream, attempts_left - 1)
    end
  end
end