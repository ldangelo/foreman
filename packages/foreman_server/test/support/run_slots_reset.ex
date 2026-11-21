defmodule ForemanServer.TestSupport.RunSlotsReset do
  @moduledoc false
  # Every project has its own `run_slots:<project_id>` aggregate (the legacy
  # `run_slots:global` stream may still exist from older tests). Tests that
  # exercise `RunAdmission.start/3` append `RunSlotAcquired` events to those
  # streams and mutate the shared actors' in-memory `holders` / `waiters`
  # state. Without a per-test reset, one file's holders persist into the next file's
  # `setup` (and the next example within a file) and downstream
  # admissions return `:slot_queued`.
  #
  # `reset!/0` mirrors `run_executor_test.exs`'s
  # `init_run_slots_capacity/0`: hard-delete every `run_slots:*` stream, kill every actor
  # (so the next lookup re-replays the now-empty stream), then reset the
  # projection store's slot view via the suite-wide helper that seeds
  # every key the production `initial_state/0` defines, passing
  # `keep_subscribers: true` so a live Dispatcher/RunLifecycleReconciler
  # subscription survives the reset (see foreman-test-isolation root
  # cause #4 — the default clobbers subscribers, which silently kills
  # the dispatch chain for tests exercising the wired Dispatcher).
  # Hard delete requires `enable_hard_deletes: true` in
  # `ForemanServer.EventStore` config, which `config/test.exs` sets.
  @stream_prefix "run_slots:"
  @page_size 100

  @spec reset!() :: :ok
  def reset! do
    # Leftover executors and Dispatcher slot releases must be done before the
    # streams are deleted and their actors killed, or they land mid-reset
    # (`run_slots.release ... exited {:killed, ...}`).
    ForemanServer.TestSupport.RunDrain.drain!()

    # One stream per project (`run_slots:<project_id>`, TRD-005) plus the
    # legacy `run_slots:global`: every one of them is reset, so no holder or
    # waiter of an earlier test can survive into the next.
    streams = run_slot_streams(1, [])

    Enum.each(streams, &hard_delete_with_retry(&1, 3))

    # The actors are stopped with `terminate_child/delete_child`, not `Process.exit(pid, :kill)`:
    # a kill is a crash the permanent child restarts from, and one stream per project means
    # hundreds of them at once, over the Aggregator's budget of 100 restarts in 5 s. The
    # Aggregator then dies with every actor and a test's `start_child` call exits `:shutdown`.
    # A terminated child is not restarted and does not count against that budget; the next
    # lookup starts a fresh actor that replays the (now empty) stream.
    Enum.each(streams, fn stream ->
      case Registry.lookup(ForemanServer.AggregateRegistry, stream) do
        [{pid, _}] when is_pid(pid) ->
          _ = Supervisor.terminate_child(ForemanServer.Aggregator, stream)
          _ = Supervisor.delete_child(ForemanServer.Aggregator, stream)

        _ ->
          :ok
      end
    end)

    # Registry entries go when the actor's process does, a moment after `terminate_child`
    # returns; wait so the next `Aggregator.start_aggregate/2` cannot see a stale dead pid.
    Process.sleep(20)

    ForemanServer.TestSupport.ProjectionStoreReset.reset!(keep_subscribers: true)
    :ok
  end

  # `paginate_streams(search: term)` matches `%term%`, so the prefix is
  # re-checked; sorting by `stream_uuid` keeps paging stable.
  defp run_slot_streams(page_number, acc) do
    opts = [
      search: @stream_prefix,
      page_number: page_number,
      page_size: @page_size,
      sort_by: :stream_uuid
    ]

    case ForemanServer.EventStore.paginate_streams(opts) do
      {:ok, %EventStore.Page{entries: entries, total_pages: total_pages}} ->
        acc =
          Enum.reduce(entries, acc, fn %EventStore.Streams.StreamInfo{stream_uuid: uuid}, acc ->
            if String.starts_with?(uuid, @stream_prefix), do: [uuid | acc], else: acc
          end)

        if page_number >= total_pages,
          do: Enum.reverse(acc),
          else: run_slot_streams(page_number + 1, acc)

      {:error, reason} ->
        raise "RunSlotsReset.reset!/0: could not list run_slots streams: #{inspect(reason)}"
    end
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
  # transaction has time to settle. Retry exhaustion raises: this helper
  # only ever runs inside a test's own `setup`, where ExUnit catches the
  # exception and fails that one test with a clear reason — it does not
  # crash the suite — so there is no reason to prefer silently continuing
  # with retained `run_slots:global` events, which is exactly the kind of
  # latent cross-test contamination this reset exists to prevent.
  #
  # `:not_supported` is not transient — it means `enable_hard_deletes` is
  # off, so every reset would forever no-op. That is a config defect, not
  # a race, and raises immediately rather than joining the retry path.
  defp hard_delete_with_retry(stream, 0) do
    raise "RunSlotsReset.reset!/0: hard delete of #{stream} did not complete " <>
            "after retrying foreign-key conflicts; refusing to continue with retained events"
  end

  defp hard_delete_with_retry(stream, attempts_left) do
    case ForemanServer.EventStore.delete_stream(stream, :any_version, :hard) do
      :ok ->
        :ok

      {:ok, _} ->
        :ok

      {:error, :stream_not_found} ->
        :ok

      {:error, :not_supported} ->
        raise "hard deletes are not enabled for #{stream}"

      {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} ->
        Process.sleep(20)
        hard_delete_with_retry(stream, attempts_left - 1)
    end
  end
end
