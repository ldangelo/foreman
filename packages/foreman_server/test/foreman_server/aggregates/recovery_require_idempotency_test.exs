defmodule ForemanServer.Aggregates.RecoveryRequireIdempotencyTest do
  @moduledoc """
  TRD-019 / S2: `recovery.require` is idempotent at the persistence boundary.

  Dispatches `recovery.require` twice with the same `command_id` against a
  fresh stream and asserts exactly one `WorkerRecoveryRequired` event lands in
  the event store. Pairs with `recovery_test.exs`'s pure-function idempotency
  test, which only proves the in-memory `handle_command/2` returns identical
  event specs — it does not exercise the store-level deduplication that the
  S2 contract depends on.

  Mirrors the AC2.2 (`run.complete`) pattern: derive the event_id from
  `{aggregate_id, command_id}` and let the second append hit the
  `events_pkey` unique constraint as a no-op. The actor receives
  `:duplicate_event` and replies with `{:ok, existing_event_spec}` without
  calling `apply_event`, so its in-memory state remains unchanged.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.CommandRouter
  alias ForemanServer.EventStore, as: Store

  defp uuid, do: Elixir.EventStore.UUID.uuid4()

  defp dispatch(command), do: CommandRouter.dispatch(command, 5_000)

  defp worker_recovery_required_count(run_id) do
    case Store.read_stream_forward("recovery:#{run_id}", 0, 99_999_999) do
      {:ok, events} ->
        Enum.count(events, fn e -> e.event_type == "WorkerRecoveryRequired" end)

      {:error, _} ->
        0
    end
  end

  defp actor_state(aggregate_id) do
    case Registry.lookup(ForemanServer.AggregateRegistry, aggregate_id) do
      [{pid, _}] -> :sys.get_state(pid).module_state
      [] -> nil
    end
  end

  test "duplicate recovery.require with the same command_id persists exactly one WorkerRecoveryRequired" do
    run_id = "run-#{uuid()}"
    agg_id = "recovery:#{run_id}"
    cmd_id = "dup-#{uuid()}"

    command = %{
      aggregate_id: agg_id,
      type: "recovery.require",
      command_id: cmd_id,
      payload: %{run_id: run_id, reason: "heartbeat_timeout"}
    }

    {:ok, first} = dispatch(command)

    assert first["event_type"] == "WorkerRecoveryRequired"
    assert first["stream_id"] == agg_id
    assert worker_recovery_required_count(run_id) == 1

    # Second dispatch with the same command_id — must be idempotent at the
    # persistence boundary (event_id is derived from {aggregate_id, command_id},
    # so the second append hits the unique constraint and no-ops).
    {:ok, second} = dispatch(command)

    assert second["event_type"] == "WorkerRecoveryRequired"
    assert second["stream_id"] == agg_id
    assert worker_recovery_required_count(run_id) == 1
  end

  test "duplicate recovery.require does not re-apply the event to the actor's in-memory state" do
    run_id = "run-#{uuid()}"
    agg_id = "recovery:#{run_id}"
    cmd_id = "dup-state-#{uuid()}"

    command = %{
      aggregate_id: agg_id,
      type: "recovery.require",
      command_id: cmd_id,
      payload: %{run_id: run_id, reason: "heartbeat_timeout"}
    }

    {:ok, _} = dispatch(command)

    state_after_first = actor_state(agg_id)
    assert state_after_first != nil
    # `recovery.require` produces `WorkerRecoveryRequired`, which the recovery
    # aggregate classifies as an observation event — it goes into `observations`
    # and sets `status: "observed"`. A duplicate must not re-apply.
    assert length(state_after_first.observations) == 1
    assert state_after_first.attempts == 0

    {:ok, _} = dispatch(command)

    state_after_second = actor_state(agg_id)

    # The actor's `apply_event` is only invoked on successful appends, so the
    # duplicate's no-op append leaves the in-memory state untouched.
    assert state_after_second.observations == state_after_first.observations
    assert state_after_second.actions == state_after_first.actions
    assert state_after_second.attempts == state_after_first.attempts
  end
end
