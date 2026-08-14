defmodule ForemanServer.RunAdmission do
  @moduledoc """
  One-way internal run-admission surface.

      Dispatcher / Reconciler -> RunAdmission.start/2 -> CommandRouter.dispatch_run_start/2 -> CommandRouter.do_dispatch/2

  Supervised workflow components MUST enter through `start/2` so
  `[:foreman, :run_admission, :start]` telemetry is emitted consistently.

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
  alias ForemanServer.{Aggregate.Actor, Aggregator, CommandGateway, CommandRouter, Telemetry}

  @type start_result ::
          {:ok, map() | nil | :queued} | {:error, any()}

  @spec start(String.t(), map(), integer()) :: start_result()
  def start(project_id, payload, timeout \\ 5_000)

  def start(project_id, payload, timeout)
      when is_binary(project_id) and project_id != "" and is_map(payload) do
    Telemetry.run_admission_start(
      project_id,
      Map.get(payload, :run_id),
      Map.get(payload, :task_id)
    )

    case acquire_beads_lease(payload, timeout) do
      :proceed ->
        case CommandRouter.dispatch_run_start(project_id, payload, timeout) do
          {:ok, _} = ok ->
            ok

          {:error, reason} = err ->
            # Compensate ONLY on errors that the caller cannot retry
            # (deterministic input / domain rejection). On those errors
            # the same `lease.acquire` command_id would dedup against
            # the original acquisition on retry, so the caller would
            # see a stale lease state and fail again — releasing here
            # lets a future attempt with a fresh command_id proceed.
            # Transient errors (timeout, wrong_expected_version, etc.)
            # preserve the lease so the caller's deterministic retry
            # remains idempotent.
            if compensable_admission_error?(reason) do
              release_after_failed_start(payload, timeout)
            end

            err
        end

      :queued ->
        {:ok, :queued}

      {:error, _reason} = err ->
        # Fail closed: never dispatch run.start when the lease
        # decision is uncertain. The next BootReconciliation sweep
        # or lease-transfer subscriber will retry this admission.
        err
    end
  end

  def start(project_id, _payload, _timeout),
    do: {:error, {:missing_or_invalid, :project_id, project_id}}

  # ---------------------------------------------------------------------------
  # Beads lease — synchronous acquire-or-enqueue with admission gating.
  # ---------------------------------------------------------------------------
  defp acquire_beads_lease(payload, timeout) do
    snapshot =
      Map.get(payload, :workflow_snapshot) || Map.get(payload, "workflow_snapshot") || %{}

    impl = Map.get(snapshot, :implementation) || Map.get(snapshot, "implementation") || %{}

    db_path = Map.get(impl, :beads_database_path) || Map.get(impl, "beads_database_path")

    run_id = Map.get(payload, :run_id)

    task_id = Map.get(payload, :task_id)

    cond do
      not (is_binary(db_path) and db_path != "") ->
        :proceed

      not (is_binary(run_id) and run_id != "" and is_binary(task_id) and task_id != "") ->
        :proceed

      true ->
        acquire_dispatch(db_path, run_id, task_id, timeout)
    end
  end

  defp acquire_dispatch(db_path, run_id, task_id, timeout) do
    command = %{
      type: "lease.acquire",
      command_id: "workflow:run-admission:lease-acquire:#{db_path}:#{run_id}",
      aggregate_id: ForemanServer.Aggregates.BeadsDbLease.stream_id(db_path),
      payload: %{
        db_path: db_path,
        run_id: run_id,
        task_id: task_id,
        acquired_at_ms: System.system_time(:millisecond)
      }
    }

    case CommandGateway.dispatch_system(command, timeout) do
      {:error, reason} ->
        {:error, {:lease_acquire_failed, reason}}

      {:ok, _event_spec_or_nil} ->
        # Inspect the live aggregate state to disambiguate idempotent
        # retries (holder vs. queued), which both return nil from the
        # aggregate's handle_command/2.
        case lease_decision(db_path, run_id, timeout) do
          :holder -> :proceed
          :queued -> :queued
          :unknown -> {:error, :lease_state_unknown}
          :unexpected -> {:error, :lease_state_unexpected}
        end
    end
  end

  defp lease_decision(db_path, run_id, timeout) do
    aggregate_id = ForemanServer.Aggregates.BeadsDbLease.stream_id(db_path)

    with {:ok, pid} <-
           Aggregator.start_aggregate(
             ForemanServer.Aggregates.BeadsDbLease,
             aggregate_id
           ),
         state when is_map(state) <- Actor.get_state(pid) do
      cond do
        holder?(state, run_id) ->
          :holder

        waiter?(state, run_id) ->
          :queued

        true ->
          :unexpected
      end
    else
      _ -> :unknown
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
    Enum.any?(waiters, fn %ForemanServer.Aggregates.BeadsDbLease.Waiter{run_id: r} ->
      r == run_id
    end)
  end

  defp waiter?(_state, _run_id), do: false

  # ---------------------------------------------------------------------------
  # Compensation: release the lease when admission deterministically failed.
  # ---------------------------------------------------------------------------

  defp compensable_admission_error?({:missing_or_invalid, _field, _value}), do: true
  defp compensable_admission_error?({:missing_or_invalid, _field}), do: true
  defp compensable_admission_error?({:implementation_already_active, _key, _run_id}), do: true
  defp compensable_admission_error?({:command_rejected, _reason}), do: true
  defp compensable_admission_error?(_other), do: false

  defp release_after_failed_start(payload, timeout) do
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
end
