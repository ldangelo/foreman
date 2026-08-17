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
  # every key the production `initial_state/0` defines. A short settle
  # delay afterwards gives the Aggregator supervisor time to finish
  # re-registering the restarted actor so the next `GenServer.call`
  # dispatches into a live pid.
  # Hard delete requires `enable_hard_deletes: true` in
  # `ForemanServer.EventStore` config, which `config/test.exs` sets.
  @spec reset!() :: :ok
  def reset! do
    stream = "run_slots:global"

    case ForemanServer.EventStore.delete_stream(stream, :any_version, :hard) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, :stream_not_found} -> :ok
    end

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

    ForemanServer.TestSupport.ProjectionStoreReset.reset!([])
    :ok
  end
end