defmodule ForemanServer.RunAdmission do
  @moduledoc """
  One-way internal run-admission surface.

      Dispatcher / Reconciler -> RunAdmission.start/2 -> CommandRouter.dispatch_run_start/2 -> CommandRouter.do_dispatch/2

  Supervised workflow components MUST enter through `start/2` so
  `[:foreman, :run_admission, :start]` telemetry is emitted consistently.

  ## Slot gate (outermost)

  The global run-slot gate is the outermost admission barrier. It consults
  `RunSlots.Config.max_concurrent_runs/0` for capacity and dispatches
  `run_slots.acquire` to the `run_slots:global` aggregate. A run that
  cannot acquire a slot immediately is durably enqueued; subsequent attempts
  with the same run_id return `:slot_queued` without reaching the lease gate.

  ## Beads lease gating

  For `implement-trd-beads` runs, the dispatcher acquires the
  per-DB Beads lease synchronously before any run.start work
  happens. Admission is gated on the lease decision:

    * Holder (this run is the holder of the lease) — proceed to
      `run.start`. Return shape: `{:ok, _}`.
    * Queued (this run is durably registered as a waiter because
      a different run_id currently holds the lease) — SKIP
      `run.start`. The Dispatcher must handle this outcome
      explicitly so a non-holder never executes concurrently.
      The lease aggregate will emit `BeadsDbLeaseTransferred`
      when the holder releases and promotes this waiter;
      a re-dispatch at that point will succeed. Return shape:
      `{:ok, :queued}`.

  Any uncertainty (acquire error, actor query failure, state
  with neither holder nor waiter for this run_id) returns
  `{:error, reason}` and skips `run.start`. Lease gating MUST
  fail closed so transient errors cannot recreate concurrent
  SQLite access.

  ## Why query aggregate state after dispatch

  `lease.acquire` is idempotent for both "already holder" and
  "already queued" — both return `{:ok, nil}` from
  `handle_command/2`. So the synchronous dispatch return alone
  cannot distinguish a successful first acquire from a retry
  that was already enqueued. After every acquire we read the
  live aggregate state via `Actor.get_state/1` and decide
  explicitly.

  ## Deterministic command IDs

  `lease.acquire` and `lease.release` carry stable command IDs
  derived from `db_path` and `run_id` so retries collapse through
  the router's idempotency path.
  """
  require Logger
  alias ForemanServer.EventStore
  alias ForemanServer.{Aggregate.Actor, CommandGateway, CommandRouter, Telemetry}
  alias ForemanServer.RunSlots.Config

  @type start_result ::
          {:ok, map() | nil | :queued | :slot_queued} | {:error, any()}

  @spec start(String.t(), map(), integer()) :: start_result()
  def start(project_id, payload, timeout \\ 5_000)

  def start(project_id, payload, timeout)
      when is_binary(project_id) and project_id != "" and is_map(payload) do
    Telemetry.run_admission_start(
      project_id,
      Map.get(payload, :run_id),
      Map.get(payload, :task_id)
    )

    # ── Slot gate (outermost) ───────────────────────────────────────────────
    case acquire_slot(payload, timeout) do
      {:error, _reason} = err ->
        err

      :slot_queued ->
        {:ok, :slot_queued}

      :slot_acquired ->
        # ── Lease gate ─────────────────────────────────────────────────────
        case acquire_beads_lease(payload, timeout) do
          :proceed ->
            # ── Dispatch ───────────────────────────────────────────────────
            case CommandRouter.dispatch_run_start(project_id, payload, timeout) do
              {:ok, _} = ok ->
                ok

              {:error, reason} = err ->
                if compensable_admission_error?(reason) do
                  release_after_failed_start(payload, timeout)
                end

                err
            end

          :queued ->
            release_after_failed_slot(payload)
            {:ok, :queued}

          {:error, _reason} = err ->
            release_after_failed_slot(payload)
            err
        end
    end
  end

  def start(project_id, _payload, _timeout),
    do: {:error, {:missing_or_invalid, :project_id, project_id}}

  # ---------------------------------------------------------------------------
  # Slot gate — global run-slot gate, outermost barrier.
  # ---------------------------------------------------------------------------

  defp acquire_slot(payload, timeout) do
    run_id = Map.get(payload, :run_id)
    capacity = Config.max_concurrent_runs()

    command = %{
      type: "run_slots.acquire",
      command_id: "workflow:run-admission:slot-acquire:#{run_id}",
      aggregate_id: "run_slots:global",
      payload: %{
        run_id: run_id,
        capacity: capacity
      }
    }

    case CommandGateway.dispatch_system(command, timeout) do
      {:error, reason} ->
        {:error, {:slot_acquire_failed, reason}}

      {:ok, _event_spec_or_nil} ->
        case slot_decision(run_id, timeout) do
          :slot_acquired -> :slot_acquired
          :slot_queued -> :slot_queued
          :unknown -> {:error, :slot_state_unknown}
        end
    end
  end

  defp slot_decision(run_id, _timeout), do: slot_decision_retry(run_id, 5)

  defp slot_decision_retry(_run_id, 0), do: :unknown

  defp slot_decision_retry(run_id, retries_left) do
    aggregate_id = "run_slots:global"

    case Registry.lookup(ForemanServer.AggregateRegistry, aggregate_id) do
      [{pid, _}] ->
        case safe_get_state(pid) do
          {:ok, state} ->
            cond do
              is_map(state) and Map.has_key?(state.holders, run_id) -> :slot_acquired
              is_map(state) and Enum.any?(state.waiters, &(&1.run_id == run_id)) -> :slot_queued
              true -> :unknown
            end

          :retry ->
            Process.sleep(20)
            slot_decision_retry(run_id, retries_left - 1)
        end

      [] ->
        # The run_slots:global actor can be mid-restart (e.g. a test's
        # force-kill reset, or a crash/restart under load) in the brief
        # window between the earlier `run_slots.acquire` dispatch (which
        # would have restarted it via Aggregator.start_aggregate) and
        # this lookup. Retry briefly instead of surfacing a false
        # "unknown" admission failure that nothing else retries.
        Process.sleep(20)
        slot_decision_retry(run_id, retries_left - 1)
    end
  end

  defp safe_get_state(pid) do
    {:ok, Actor.get_state(pid)}
  catch
    :exit, _reason -> :retry
  end

  defp release_after_failed_slot(payload) do
    run_id = Map.get(payload, :run_id)

    if is_binary(run_id) and run_id != "" do
      ms = System.system_time(:millisecond)

      _ =
        CommandGateway.dispatch_system(%{
          type: "run_slots.release",
          command_id: "workflow:run-admission:slot-release:#{run_id}:#{ms}",
          aggregate_id: "run_slots:global",
          payload: %{
            run_id: run_id
          }
        })

      :ok
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Beads lease — synchronous acquire-or-enqueue with admission gating.
  # ---------------------------------------------------------------------------

  defp acquire_beads_lease(payload, timeout) do
    snapshot =
      Map.get(payload, :workflow_snapshot) || Map.get(payload, "workflow_snapshot") || %{}

    impl = Map.get(snapshot, :implementation) || Map.get(snapshot, "implementation") || %{}

    db_path = Map.get(impl, :beads_database_path) || Map.get(impl, "beads_database_path")

    if is_binary(db_path) and db_path != "" do
      run_id = Map.get(payload, :run_id)
      task_id = Map.get(payload, :task_id)
      acquire_dispatch(db_path, run_id, task_id, timeout)
      lease_decision(db_path, run_id, timeout)
    else
      :proceed
    end
  end

  defp acquire_dispatch(db_path, run_id, task_id, _timeout) do
    ms = System.system_time(:millisecond)

    CommandGateway.dispatch_system(%{
      type: "lease.acquire",
      command_id: "workflow:run-admission:lease-acquire:#{db_path}:#{run_id}:#{ms}",
      aggregate_id: ForemanServer.Aggregates.BeadsDbLease.stream_id(db_path),
      payload: %{
        db_path: db_path,
        run_id: run_id,
        task_id: task_id,
        acquired_at_ms: ms
      }
    })
  end

  defp lease_decision(db_path, run_id, _timeout) do
    aggregate_id = ForemanServer.Aggregates.BeadsDbLease.stream_id(db_path)

    case Registry.lookup(ForemanServer.AggregateRegistry, aggregate_id) do
      [{pid, _}] ->
        state = Actor.get_state(pid)

        cond do
          holder?(state, run_id) -> :proceed
          waiter?(state, run_id) -> :queued
          true -> {:error, :lease_state_unknown}
        end

      [] ->
        {:error, :lease_state_unknown}
    end
  end

  defp holder?(
         %ForemanServer.Aggregates.BeadsDbLease.State{
           holder: %ForemanServer.Aggregates.BeadsDbLease.Holder{run_id: r}
         },
         run_id
       ),
       do: r == run_id

  defp holder?(_state, _run_id), do: false

  defp waiter?(%ForemanServer.Aggregates.BeadsDbLease.State{waiters: waiters}, run_id) do
    Enum.any?(waiters, &(&1.run_id == run_id))
  end

  defp waiter?(_state, _run_id), do: false

  # ---------------------------------------------------------------------------
  # Compensation: release the slot when admission deterministically failed.
  # ---------------------------------------------------------------------------

  defp compensable_admission_error?({:missing_or_invalid, _field, _value}), do: true
  defp compensable_admission_error?({:missing_or_invalid, _field}), do: true
  defp compensable_admission_error?({:implementation_already_active, _key, _run_id}), do: true
  defp compensable_admission_error?({:command_rejected, _reason}), do: true
  defp compensable_admission_error?(_other), do: false

  defp release_after_failed_start(payload, timeout) do
    # Release the slot first so capacity is restored.
    release_after_failed_slot(payload)

    # Then release the lease if present.
    snapshot =
      Map.get(payload, :workflow_snapshot) || Map.get(payload, "workflow_snapshot") || %{}

    impl = Map.get(snapshot, :implementation) || Map.get(snapshot, "implementation") || %{}

    db_path =
      Map.get(impl, :beads_database_path) || Map.get(impl, "beads_database_path")

    run_id = Map.get(payload, :run_id)

    if is_binary(db_path) and db_path != "" and is_binary(run_id) and run_id != "" do
      ms = System.system_time(:millisecond)

      _ =
        CommandGateway.dispatch_system(%{
          type: "lease.release",
          command_id: "workflow:run-admission:lease-release:#{db_path}:#{run_id}:#{ms}",
          aggregate_id: ForemanServer.Aggregates.BeadsDbLease.stream_id(db_path),
          payload: %{
            db_path: db_path,
            run_id: run_id,
            released_at_ms: ms,
            reason: "admission_failed"
          }
        })

      :ok
    else
      :ok
    end
  end

  # --------------------------------------------------------------------------------
  # Public recovery API
  # --------------------------------------------------------------------------------

  alias ForemanServer.Aggregates.Run

  @doc """
  Reconstruct the current `Run` aggregate state by replaying the event stream
  for `run:<run_id>`. Returns `{:ok, state, event_count}` on success or
  `{:error, reason}` if the stream is missing or reconstruction fails.

  Use this to get the authoritative run state when the projection may be stale.
  """
  @spec reconstruct_state(String.t()) ::
          {:ok, Run.State.t(), non_neg_integer()} | {:error, :stream_not_found | term()}
  def reconstruct_state(run_id) when is_binary(run_id) do
    stream_id = "run:#{run_id}"

    # Check stream existence by reading the first event; missing stream → :stream_not_found.
    case EventStore.read_stream_forward(stream_id, 0, 1) do
      {:ok, _events} ->
        case Run.load(stream_id) do
          {state, version} ->
            {:ok, state, version}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :stream_not_found} ->
        {:error, :stream_not_found}
    end
  end

end
