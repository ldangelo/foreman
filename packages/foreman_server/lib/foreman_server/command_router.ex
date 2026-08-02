defmodule ForemanServer.CommandRouter do
  @moduledoc "Command boundary for server-side project/task mutations."

  alias ForemanServer.{
    Aggregate,
    AggregateRouter,
    EventStore,
    Inbox,
    IntegrationIngestion,
    MigrationImporter,
    PlanningFlow,
    ProjectionStore,
    Security
  }

  @external_trigger_types ["ExternalTriggerCommand", "external.trigger"]
  @planning_command_types ["PlanningFlowCommand", "plan.prd", "plan.trd"]
  @migration_command_types ["MigrationImportCommand", "migration.import"]
  @task_statuses MapSet.new([
                   "backlog",
                   "ready",
                   "approved",
                   "in_progress",
                   "in-progress",
                   "review",
                   "merged",
                   "closed",
                   "conflict",
                   "failed",
                   "stuck",
                   "blocked",
                   "cooldown"
                 ])
@max_router_retries 3
  @max_slot_retries 100
  @spec handle(map()) :: {:ok, map()} | {:error, term()}
  def handle(%{"command_type" => command_type} = command)
      when command_type in @planning_command_types do
    command
    |> normalize_payload()
    |> Map.put(:command_type, command_type)
    |> Map.put_new(:command_id, external_command_id(command))
    |> handle()
  end

  def handle(%{"command_type" => command_type} = command)
      when command_type in @migration_command_types do
    command
    |> normalize_payload()
    |> Map.put(:command_type, command_type)
    |> Map.put_new(:command_id, external_command_id(command))
    |> handle()
  end

  def handle(%{"command_type" => command_type} = command)
      when command_type in @external_trigger_types do
    command
    |> normalize_payload()
    |> Map.put(:command_type, command_type)
    |> Map.put_new(:command_id, external_command_id(command))
    |> handle()
  end

  def handle(%{"command_id" => command_id, "command_type" => command_type} = command) do
    handle(%{
      command_id: command_id,
      command_type: command_type,
      correlation_id: Map.get(command, "correlation_id"),
      payload: Map.get(command, "payload", %{}),
      metadata: Map.get(command, "metadata", %{})
    })
  end

  def handle(%{command_type: command_type} = command)
      when command_type in @planning_command_types do
    command_id = Map.get(command, :command_id) || external_command_id(command)
    metadata = normalize_metadata(Map.put(command, :command_id, command_id))

    command
    |> planning_payload(command_type)
    |> Map.put_new(:command_id, command_id)
    |> handle_planning_flow(metadata)
  end

  def handle(%{command_type: command_type} = command)
      when command_type in @migration_command_types do
    command_id = Map.get(command, :command_id) || external_command_id(command)
    metadata = normalize_metadata(Map.put(command, :command_id, command_id))

    command
    |> migration_payload()
    |> Map.put_new(:command_id, command_id)
    |> Map.put_new(:migration_id, command_id)
    |> handle_migration_import(metadata)
  end

  def handle(%{command_type: "inbox.send"} = command) do
    command_id = Map.get(command, :command_id) || external_command_id(command)

    command
    |> external_trigger_payload()
    |> Map.put_new(:message_id, command_id)
    |> Inbox.send_operator_message()
    |> case do
      {:ok, %{event: event, projection: projection, result: result}} ->
        {:ok, %{event: event, projection: projection, inbox: result}}

      error ->
        error
    end
  end

  def handle(%{command_type: command_type} = command)
      when command_type in @external_trigger_types do
    command_id = Map.get(command, :command_id) || external_command_id(command)
    metadata = normalize_metadata(Map.put(command, :command_id, command_id))

    command
    |> external_trigger_payload()
    |> Map.put_new(:command_id, command_id)
    |> handle_external_trigger(metadata)
  end

  def handle(%{command_id: command_id, command_type: "run.start"} = command)
      when is_binary(command_id) do
    payload = normalize_payload(Map.get(command, :payload, %{}))

    if not is_map(payload) do
      {:error, :invalid_payload}
    else
      payload = Map.put_new(payload, :command_id, command_id)
      metadata = normalize_metadata(command)

      case run_start_saga(payload, command_id, metadata) do
        {:ok, event, enriched_payload} ->
          case maybe_audit(command, event.event_type, enriched_payload) do
            {:ok, audit_events} ->
              {:ok,
               %{event: event, audit_events: audit_events, projection: ProjectionStore.snapshot()}}

            error ->
              error
          end

        {:error, _} = error ->
          error
      end
    end
  end

  def handle(%{command_id: command_id, command_type: command_type} = command)
      when is_binary(command_id) and
             command_type in ["run.complete", "run.fail", "run.cancel"] do
    payload = normalize_payload(Map.get(command, :payload, %{}))

    if not is_map(payload) do
      {:error, :invalid_payload}
    else
      payload = Map.put_new(payload, :command_id, command_id)
      metadata = normalize_metadata(command)

      case run_terminal_saga(command_type, payload, command_id, metadata) do
        {:ok, event, enriched_payload} ->
          case maybe_audit(command, event.event_type, enriched_payload) do
            {:ok, audit_events} ->
              {:ok,
               %{event: event, audit_events: audit_events, projection: ProjectionStore.snapshot()}}

            error ->
              error
          end

        {:error, _} = error ->
          error
      end
    end
  end

  def handle(%{command_id: command_id, command_type: "project_run_limit.reconcile"} = command)
      when is_binary(command_id) do
    payload = normalize_payload(Map.get(command, :payload, %{}))

    if not is_map(payload) do
      {:error, :invalid_payload}
    else
      payload = Map.put_new(payload, :command_id, command_id)
      metadata = normalize_metadata(command)

      project_id = Map.get(payload, :project_id)
      run_id = Map.get(payload, :run_id)

      cond do
        not (is_binary(project_id) and project_id != "") ->
          {:error, {:missing_or_invalid, :project_id}}

        not (is_binary(run_id) and run_id != "") ->
          {:error, {:missing_or_invalid, :run_id}}

        true ->
          case reconcile_slot(project_id, run_id, payload, command_id, metadata) do
            {:ok, status} -> {:ok, status}
            {:error, _} = err -> err
          end
      end
    end
  end

  def handle(%{command_id: command_id, command_type: command_type} = command)
      when is_binary(command_id) and is_binary(command_type) do
    payload =
      normalize_payload(command_type, Map.get(command, :payload, %{}))
      |> Map.put_new(:command_id, command_id)

    metadata = normalize_metadata(command)

    case do_append(command_type, payload, command_id, metadata, @max_router_retries) do
      {:ok, event, enriched_payload} ->
        case maybe_audit(command, event.event_type, enriched_payload) do
          {:ok, audit_events} ->
            {:ok,
             %{event: event, audit_events: audit_events, projection: ProjectionStore.snapshot()}}

          error ->
            error
        end

      {:error, _} = error ->
        error
    end
  end

  def handle(_command), do: {:error, :invalid_command}

  # Bounded retry for optimistic concurrency conflicts. On
  # :wrong_expected_version we re-call command_event/2 which routes through
  # AggregateRouter → Aggregate.decide/4; that re-loads the current state and
  # either returns a fresh spec (with the new expected_stream_version) OR a
  # logical rejection such as :phase_terminal — both are correct resolutions.
  # Also gates on the stream-gap detector (TRD-041 / AC-021-3) so a
  # detected gap blocks further appends on the affected stream.
  defp do_append(command_type, payload, command_id, metadata, retries_left) do
    with {:ok, event_spec} <- command_event(command_type, payload),
         event_type = Map.fetch!(event_spec, :event_type),
         enriched_payload =
           event_spec
           |> Map.fetch!(:payload)
           |> Map.put_new(:command_id, command_id)
           |> Map.put_new(:updated_at, DateTime.utc_now()),
         append_input =
           %{
             stream_id: Map.fetch!(event_spec, :stream_id),
             event_type: event_type,
             payload: enriched_payload,
             metadata: metadata,
             correlation_id: Map.get(metadata, :correlation_id)
           }
           |> maybe_put_expected_version(Map.get(event_spec, :expected_stream_version)),
         :ok <- check_stream_gap(command_type, Map.fetch!(append_input, :stream_id)),
         {:ok, event} <- EventStore.append(append_input) do
      {:ok, event, enriched_payload}
    else
      {:error, :wrong_expected_version} when retries_left > 0 ->
        do_append(command_type, payload, command_id, metadata, retries_left - 1)

      {:error, :wrong_expected_version} ->
        # Retries exhausted — surface the original conflict atom so callers
        # see the same shape they always did. TRD-008 / TRD-008-TEST's
        # contract is "append fails with concurrency conflict"; callers
        # must keep observing :wrong_expected_version for that case.
        {:error, :wrong_expected_version}

      # EventStore on this tree returns `{:conflict, [expected: x, actual: y]}`
      # until 05dee032 (refactor) lands; treat that as a retryable conflict too
      # so the run-limit saga can re-decide against the fresh slot state.
      {:error, {:conflict, _}} when retries_left > 0 ->
        do_append(command_type, payload, command_id, metadata, retries_left - 1)

      {:error, {:conflict, _}} ->
        {:error, :wrong_expected_version}

      {:error, _} = other ->
        other
    end
  end

  # TRD-041 / AC-021-3, AC-022-1, AC-022-2 — checked slot append.
  #
  # Slot reservation/release use `Aggregate.decide/4` to compute an event
  # spec OUTSIDE of `do_append/5` (which derives the spec from the
  # command_type via AggregateRouter). To keep the gap-guard as the
  # single enforcement point for "no append without a check", slot
  # operations route through this helper instead of calling
  # `EventStore.append/1` directly. The helper:
  #
  #   * Consults `check_stream_gap/2` with the supplied `command_type`
  #     so the `stream_gap.detect` exemption still applies (no-op for
  #     slot ops in practice — they use `run.start`/`run.complete` —
  #     but consistent with the do_append path).
  #   * Refuses with `{:error, :stream_gap}` if the slot stream is
  #     blocked, so the run.start saga propagates the rejection to
  #     the caller instead of writing a slot to a drift-suspect
  #     stream.
  #   * Returns `{:ok, event}` (NOT a 3-tuple) because the slot
  #     reservation path expects the 2-tuple shape.
  defp checked_slot_append(command_type, event_spec, command_id, metadata) do
    append_input =
      %{
        stream_id: Map.fetch!(event_spec, :stream_id),
        event_type: Map.fetch!(event_spec, :event_type),
        payload:
          Map.fetch!(event_spec, :payload)
          |> Map.put_new(:command_id, command_id)
          |> Map.put_new(:updated_at, DateTime.utc_now()),
        metadata: metadata,
        correlation_id: Map.get(metadata, :correlation_id)
      }
      |> maybe_put_expected_version(Map.get(event_spec, :expected_stream_version))

    with :ok <- check_stream_gap(command_type, Map.fetch!(append_input, :stream_id)),
         {:ok, event} <- EventStore.append(append_input) do
      {:ok, event}
    end
  end

  defp check_stream_gap("stream_gap.detect", _stream_id), do: :ok

  defp check_stream_gap(_command_type, stream_id) do
    case run_gap_check(stream_id) do
      :blocked -> {:error, :stream_gap}
      _ -> :ok
    end
  end

  defp run_gap_check(stream_id) do
    if Process.whereis(ForemanServer.StreamGapDetector) do
      ForemanServer.StreamGapDetector.check(stream_id)
    else
      :ok
    end
  end

  defp command_event(command_type, payload) do
    case AggregateRouter.route(command_type, payload) do
      {:ok, event_spec} -> {:ok, event_spec}
      :unhandled -> legacy_domain_event(command_type, payload)
      {:error, reason} -> {:error, reason}
    end
  end

  defp legacy_domain_event(command_type, payload) do
    with {:ok, event_type, event_payload, stream_id} <- domain_event(command_type, payload) do
      {:ok, %{event_type: event_type, payload: event_payload, stream_id: stream_id}}
    end
  end

  # TRD-041 / AC-022-1, AC-022-2 — run.start saga.
  #
  #   1. Reserve a slot in `project_run_limit:<project_id>` via
  #      `Aggregate.decide(ProjectRunLimit, ..., "run.start", payload)`.
  #        * `{:ok, spec}` — fresh slot acquired by THIS call; append it.
  #        * `:unhandled` — slot was already counted for this run_id (idempotent
  #          re-dispatch). No new slot; do NOT compensate later.
  #        * `{:error, :run_limit_exceeded}` — project is at the 100-active cap.
  #          Append a `ProjectRunLimitRejected` audit event and return the error.
  #        * `{:error, _}` — bubble up.
  #   2. Append the canonical `RunStarted` to `run:<run_id>` (Run aggregate).
  #   3. On canonical failure, release the slot ONLY if THIS call acquired it.
  #
  # The slot stream is multi-writer (concurrent `run.start`s from the
  # scheduler). `Aggregate.decide` re-loads state on every call, so a
  # `:wrong_expected_version` from EventStore.append is recovered by
  # re-deciding against the latest state — the re-decide may now return
  # success, `:unhandled` (the run_id was inserted by a racing writer), or
  # `:run_limit_exceeded` (a racing writer filled the cap). All three are
  # correct resolutions; we surface them honestly.
  defp run_start_saga(payload, command_id, metadata) do
    project_id = Map.get(payload, :project_id)
    run_id = Map.get(payload, :run_id)

    with {:ok, run_id} <- ensure_run_id(run_id, payload),
         {:ok, project_id} <- ensure_project_id(project_id, run_id),
         payload = Map.merge(payload, %{run_id: run_id, project_id: project_id}) do
      case reserve_slot(project_id, run_id, payload, command_id, metadata) do
        {:ok, :reserved} ->
          case canonical_existing_run(run_id, project_id) do
            {:ok, _event, _enriched} = existing ->
              existing

            {:error, {:missing_canonical_run, ^run_id}} ->
              case do_append("run.start", payload, command_id, metadata, @max_router_retries) do
                {:ok, _event, _enriched} = ok ->
                  ok

                {:error, _reason} = err ->
                  release_slot(project_id, run_id, payload, command_id, metadata)
                  err
              end

            {:error, _} = err ->
              release_slot(project_id, run_id, payload, command_id, metadata)
              err
          end

        {:ok, :already_reserved} ->
          canonical_existing_run(run_id, project_id)

        {:error, :run_limit_exceeded} = err ->
          audit_run_limit_rejected(project_id, run_id, payload, command_id, metadata)
          err

        {:error, _} = err ->
          err
      end
    end
  end

  defp ensure_run_id(nil, _payload), do: {:error, :run_id_required}
  defp ensure_run_id("", _payload), do: {:error, :run_id_required}

  defp ensure_run_id(run_id, _payload) when is_binary(run_id), do: {:ok, run_id}

  defp ensure_project_id(nil, run_id) do
    case ForemanServer.Operations.Inspect.run_state(run_id) do
      %{project_id: project_id} when is_binary(project_id) and project_id != "" ->
        {:ok, project_id}

      _ ->
        {:error, :project_id_required}
    end
  end

  defp ensure_project_id("", run_id), do: ensure_project_id(nil, run_id)

  defp ensure_project_id(project_id, _run_id)
       when is_binary(project_id) and project_id != "",
       do: {:ok, project_id}

  defp canonical_existing_run(run_id, project_id) do
    case ForemanServer.Operations.Inspect.run_state(run_id) do
      %{project_id: ^project_id, status: "in_progress"} = run ->
        case EventStore.stream("run:#{run_id}") do
          [event | _] -> {:ok, event, run}
          [] -> {:error, {:missing_canonical_run, run_id}}
        end

      %{project_id: existing_project_id} when is_binary(existing_project_id) ->
        {:error, {:run_identity_conflict, run_id, existing_project_id}}

      _ ->
        {:error, {:missing_canonical_run, run_id}}
    end
  end

  # TRD-041 / AC-022-2 — run.complete / run.fail / run.cancel saga.
  #
  #   1. Emit the canonical `RunCompleted` / `RunFailed` / `RunCancelled` to
  #      `run:<run_id>` (Run aggregate).
  #   2. On canonical success, release the slot in
  #      `project_run_limit:<project_id>`.
  #
  # Slot release is best-effort after a successful canonical emit: the run
  # is already terminal in its own stream, so a missed slot release is
  # reconciled by `ProjectRunLimitSweeper`, which scans slot streams,
  # checks `Run.terminal?` against the canonical run stream, and emits
  # a `ProjectRunSlotReleased` compensating event. We audit but do not
  # roll back the canonical terminal event.
  defp run_terminal_saga(command_type, payload, command_id, metadata) do
    run_id = Map.get(payload, :run_id)

    case do_append(command_type, payload, command_id, metadata, @max_router_retries) do
      {:ok, _event, _enriched} = ok ->
        case ensure_project_id(Map.get(payload, :project_id), run_id) do
          {:ok, project_id} when is_binary(run_id) and run_id != "" ->
            release_payload =
              payload
              |> Map.put(:project_id, project_id)
              |> Map.put(:run_id, run_id)

            case release_slot(project_id, run_id, release_payload, command_id, metadata) do
              {:ok, _} ->
                ok

              {:error, release_reason} ->
                # Best-effort: do not roll back a successful canonical emit.
                audit_slot_release_failed(
                  project_id,
                  run_id,
                  command_type,
                  release_reason,
                  command_id,
                  metadata
                )

                ok
            end

          _ ->
            # No project_id resolvable from payload or run projection; the
            # ProjectRunLimitSweeper will reconcile this run if a slot was
            # actually held. Don't roll back the canonical terminal event.
            ok
        end
      {:error, _} = err ->
        # Canonical emit failed (e.g. Run aggregate rejected the transition).
        # No slot to release — the reservation (if any) is the saga's
        # responsibility; the start saga's compensation handles that path.
        err
    end
  end

  defp reserve_slot(
         project_id,
         run_id,
         payload,
         command_id,
         metadata,
         retries_left \\ @max_slot_retries
       ) do
    stream_id = "project_run_limit:#{project_id}"

    case Aggregate.decide(
           ForemanServer.Aggregates.ProjectRunLimit,
           stream_id,
           "run.start",
           payload
         ) do
      :unhandled ->
        {:ok, :already_reserved}

      {:ok, spec} ->
        case checked_slot_append("run.start", spec, command_id, metadata) do
          {:ok, _event} ->
            {:ok, :reserved}

          {:error, :wrong_expected_version} when retries_left > 0 ->
            # A concurrent reservation advanced the stream. Re-decide against
            # the freshest state; that may yield :reserved, :already_reserved,
            # or :run_limit_exceeded depending on what the other writer did.
            reserve_slot(
              project_id,
              run_id,
              payload,
              command_id,
              metadata,
              retries_left - 1
            )

          {:error, {:conflict, _}} when retries_left > 0 ->
            # EventStore on this tree returns `{:conflict, [expected: x, actual: y]}`
            # until 05dee032 lands; treat the keyword-list conflict as a
            # retryable version mismatch and re-decide against freshest state.
            reserve_slot(
              project_id,
              run_id,
              payload,
              command_id,
              metadata,
              retries_left - 1
            )

          {:error, :run_limit_exceeded} = err ->
            err

          {:error, _} = err ->
            err
        end

      {:error, :run_limit_exceeded} = err ->
        err

      {:error, _} = err ->
        err
    end
  end

  defp release_slot(
         project_id,
         run_id,
         payload,
         command_id,
         metadata,
         retries_left \\ @max_slot_retries
       ) do
    stream_id = "project_run_limit:#{project_id}"

    case Aggregate.decide(
           ForemanServer.Aggregates.ProjectRunLimit,
           stream_id,
           "run.complete",
           payload
         ) do
      :unhandled ->
        {:ok, :already_released}

      {:ok, spec} ->
        case checked_slot_append("run.complete", spec, command_id, metadata) do
          {:ok, _event} ->
            {:ok, :released}

          {:error, :wrong_expected_version} when retries_left > 0 ->
            release_slot(
              project_id,
              run_id,
              payload,
              command_id,
              metadata,
              retries_left - 1
            )

          {:error, {:conflict, _}} when retries_left > 0 ->
            # EventStore on this tree returns `{:conflict, kwl}` until
            # 05dee032 lands; retry as a version mismatch.
            release_slot(
              project_id,
              run_id,
              payload,
              command_id,
              metadata,
              retries_left - 1
            )

          {:error, _} = err ->
            err
        end

      {:error, _} = err ->
        err
    end
  end

  # TRD-041-FOLLOWUP (`for-k1l`): compensating release path invoked by
  # `ProjectRunLimitSweeper`. Bypasses the canonical run stream entirely
  # (no `RunCompleted` / `RunFailed` / `RunCancelled` appended to
  # `run:<run_id>`) and emits `ProjectRunSlotReleased` on the slot stream
  # only. Idempotent — same retry contract as `release_slot/6`.
  defp reconcile_slot(
         project_id,
         run_id,
         payload,
         command_id,
         metadata,
         retries_left \\ @max_slot_retries
       ) do
    stream_id = "project_run_limit:#{project_id}"

    case Aggregate.decide(
           ForemanServer.Aggregates.ProjectRunLimit,
           stream_id,
           "project_run_limit.reconcile",
           payload
         ) do
      :unhandled ->
        {:ok, :already_released}

      {:ok, spec} ->
        case checked_slot_append(
               "project_run_limit.reconcile",
               spec,
               command_id,
               metadata
             ) do
          {:ok, _event} ->
            {:ok, :released}

          {:error, :wrong_expected_version} when retries_left > 0 ->
            reconcile_slot(
              project_id,
              run_id,
              payload,
              command_id,
              metadata,
              retries_left - 1
            )

          {:error, _} = err ->
            err
        end

      {:error, _} = err ->
        err
    end
  end

  defp audit_run_limit_rejected(project_id, run_id, payload, command_id, metadata) do
    audit_payload =
      payload
      |> Map.put(:project_id, project_id)
      |> Map.put(:run_id, run_id)
      |> Map.put(:command_id, command_id)
      |> Map.put(:rejected_at, DateTime.utc_now())
      |> Map.put(:reason, "run_limit_exceeded")

    append_input = %{
      stream_id: "project_run_limit:#{project_id}",
      event_type: "RunLimitRejected",
      payload: audit_payload,
      metadata: metadata,
      correlation_id: Map.get(metadata, :correlation_id)
    }

    # Best-effort audit. The ProjectRunLimit aggregate treats RunLimitRejected
    # as a no-op (unknown event type) so it does not perturb the slot count.
    case EventStore.append(append_input) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  defp audit_slot_release_failed(project_id, run_id, command_type, reason, command_id, metadata) do
    audit_payload =
      Map.new(
        project_id: project_id,
        run_id: run_id,
        command_type: command_type,
        reason: inspect(reason),
        command_id: command_id,
        audited_at: DateTime.utc_now()
      )

    event_spec = %{
      stream_id: "project_run_limit:#{project_id}",
      event_type: "ProjectRunSlotReleaseFailed",
      payload: audit_payload
    }
    # Best-effort audit. The canonical reconciliation path is
    # `ProjectRunLimitSweeper`, which scans slot streams for canonical-
    # terminal runs and emits `ProjectRunSlotReleased` compensating
    # events on the slot stream itself. The audit is also gap-guarded:
    # writing an audit event onto a drift-suspect slot stream would
    # only deepen the drift, so we route through `checked_slot_append/4`.
    # If the guard refuses, the audit is silently dropped — the canonical
    # terminal event has already landed, so the operator still has the
    # run-stream record. The sweeper can only reconcile AFTER the
    # underlying gap is repaired and `StreamGapDetector.resolve/1`
    # unblocks the slot stream; until then the sweep's compensating
    # append is itself gap-refused and the slot stays leaked.

    _ =
      checked_slot_append(
        "project_run_limit.audit_slot_release_failed",
        event_spec,
        command_id,
        metadata
      )

    :ok
  end

  defp domain_event("project.register", payload) do
    project_id = Map.get(payload, :project_id) || Map.get(payload, :id)

    with {:ok, project_id} <- required_binary(project_id, :project_id),
         {:ok, path} <- required_binary(Map.get(payload, :path), :path) do
      {:ok, "ProjectRegistered",
       %{
         project_id: project_id,
         path: path,
         status: Map.get(payload, :status, "active"),
         default_branch: Map.get(payload, :default_branch, "main"),
         config: Map.get(payload, :config, %{}),
         health: Map.get(payload, :health, %{ok: true})
       }, "project:#{project_id}"}
    end
  end

  defp domain_event("project.update", payload) do
    project_id = Map.get(payload, :project_id) || Map.get(payload, :id)

    with {:ok, project_id} <- required_binary(project_id, :project_id),
         :ok <- require_existing_project(project_id) do
      {:ok, "ProjectUpdated", Map.put(payload, :project_id, project_id), "project:#{project_id}"}
    end
  end

  defp domain_event("project.archive", payload) do
    project_id = Map.get(payload, :project_id) || Map.get(payload, :id)

    with {:ok, project_id} <- required_binary(project_id, :project_id),
         :ok <- require_existing_project(project_id) do
      {:ok, "ProjectArchived",
       %{
         project_id: project_id,
         status: "archived",
         force: Map.get(payload, :force, false),
         reason: Map.get(payload, :reason)
       }, "project:#{project_id}"}
    end
  end

  defp domain_event("task.create", payload) do
    task_id = Map.get(payload, :task_id) || Map.get(payload, :id)

    if is_binary(task_id) and task_id != "" do
      {:ok, "TaskCreated",
       %{
         task_id: task_id,
         project_id: Map.get(payload, :project_id),
         title: Map.get(payload, :title, task_id),
         description: Map.get(payload, :description),
         priority: Map.get(payload, :priority),
         status: Map.get(payload, :status, "open"),
         dependencies: Map.get(payload, :dependencies, []),
         task_type: Map.get(payload, :task_type) || Map.get(payload, :type),
         source: Map.get(payload, :source),
         external_id: Map.get(payload, :external_id),
         external_link: Map.get(payload, :external_link),
         dedupe_key: Map.get(payload, :dedupe_key),
         integration_event_type: Map.get(payload, :integration_event_type),
         planning_run_id: Map.get(payload, :planning_run_id),
         planning_kind: Map.get(payload, :planning_kind),
         planning_phase_id: Map.get(payload, :planning_phase_id),
         trace_event_id: Map.get(payload, :trace_event_id)
       }, "task:#{task_id}"}
    else
      command_accepted("task.create", payload)
    end
  end

  defp domain_event("task.approve", payload),
    do: task_status_event("task.approve", payload, "ready")

  defp domain_event("task.block", payload),
    do: task_status_event("task.block", payload, "blocked")

  defp domain_event("task.close", payload), do: task_status_event("task.close", payload, "closed")

  defp domain_event("task.update", payload) do
    with {:ok, task_id} <- required_binary(Map.get(payload, :task_id), :task_id),
         :ok <- validate_task_status(Map.get(payload, :status)) do
      {:ok, "TaskUpdated", Map.put(payload, :task_id, task_id), "task:#{task_id}"}
    end
  end

  defp domain_event("task.annotate", payload) do
    with {:ok, task_id} <- required_binary(Map.get(payload, :task_id), :task_id),
         {:ok, body} <- required_binary(Map.get(payload, :body), :body) do
      {:ok, "TaskAnnotated", %{task_id: task_id, body: body, author: Map.get(payload, :author)},
       "task:#{task_id}"}
    end
  end

  defp domain_event("task.add_dependency", payload) do
    with {:ok, task_id} <- required_binary(Map.get(payload, :task_id), :task_id),
         {:ok, depends_on} <- required_binary(Map.get(payload, :depends_on), :depends_on) do
      {:ok, "TaskDependencyAdded", %{task_id: task_id, depends_on: depends_on}, "task:#{task_id}"}
    end
  end

  defp domain_event("run.start", payload) do
    with {:ok, run_id} <- required_binary(Map.get(payload, :run_id), :run_id) do
      {:ok, "RunStarted", Map.put(payload, :run_id, run_id), "run:#{run_id}"}
    end
  end

  defp domain_event("run.update", payload) do
    with {:ok, run_id} <- required_binary(Map.get(payload, :run_id), :run_id) do
      {:ok, "RunUpdated", Map.put(payload, :run_id, run_id), "run:#{run_id}"}
    end
  end

  defp domain_event(command_type, payload) when command_type in ["run.retry", "run.reset"] do
    with {:ok, run_id} <- required_binary(Map.get(payload, :run_id), :run_id),
         {:ok, task_id} <- required_binary(Map.get(payload, :task_id), :task_id),
         :ok <- require_existing_run(run_id),
         :ok <- require_existing_task(task_id) do
      default_reason =
        if command_type == "run.retry", do: "retry requested", else: "reset requested"

      reason = Map.get(payload, :reason) || default_reason

      task_payload =
        payload
        |> Map.put(:run_id, run_id)
        |> Map.put(:task_id, task_id)
        |> Map.put(:status, "ready")
        |> Map.put(:reason, reason)
        |> Map.put_new(:source, "command_bus")

      {:ok, "TaskUpdated", task_payload, "task:#{task_id}"}
    end
  end

  defp domain_event(command_type, payload)
       when command_type in [
              "run.pr.update",
              "run.pr.ready",
              "run.pr.retarget",
              "run.pr.reset",
              "run.pr.merge"
            ] do
    event_type =
      %{
        "run.pr.update" => "PrUpdated",
        "run.pr.ready" => "PrReady",
        "run.pr.retarget" => "PrRetargeted",
        "run.pr.reset" => "PrReset",
        "run.pr.merge" => "PrMerged"
      }[command_type]

    with {:ok, run_id} <- required_binary(Map.get(payload, :run_id), :run_id) do
      {:ok, event_type, Map.put(payload, :run_id, run_id), "run:#{run_id}"}
    end
  end

  defp domain_event("run.delete", payload) do
    with {:ok, run_id} <- required_binary(Map.get(payload, :run_id), :run_id) do
      {:ok, "RunDeleted", Map.put(payload, :run_id, run_id), "run:#{run_id}"}
    end
  end

  defp domain_event("event.log", payload) do
    event_type = Map.get(payload, :event_type, "cli-event")

    stream_id =
      case Map.get(payload, :run_id) do
        run_id when is_binary(run_id) and run_id != "" -> "run:#{run_id}"
        _ -> "project:#{Map.get(payload, :project_id, "unknown")}:events"
      end

    {:ok, "CliEventLogged", Map.put(payload, :event_type, event_type), stream_id}
  end

defp domain_event("stream_gap.detect", payload) do
    affected_stream_id = Map.get(payload, :affected_stream_id)

    if is_binary(affected_stream_id) and affected_stream_id != "" do
      {:ok, "StreamGapDetected", Map.put(payload, :affected_stream_id, affected_stream_id),
       "stream_gap_alerts"}
    else
      {:error, :affected_stream_id_required}
    end
  end
  defp domain_event(command_type, command), do: command_accepted(command_type, command)

  defp require_existing_project(project_id) do
    if ProjectionStore.project(project_id) do
      :ok
    else
      {:error, {:not_found, :project, project_id}}
    end
  end

  defp require_existing_run(run_id) do
    if Map.has_key?(ProjectionStore.snapshot().runs, run_id) do
      :ok
    else
      {:error, {:not_found, :run, run_id}}
    end
  end

  defp require_existing_task(task_id) do
    if ProjectionStore.task(task_id) do
      :ok
    else
      {:error, {:not_found, :task, task_id}}
    end
  end

  defp command_accepted(command_type, command) do
    {:ok, "CommandAccepted",
     %{
       command_id: Map.get(command, :command_id),
       command_type: command_type,
       status: "accepted",
       input: command
     }, "command:#{Map.get(command, :command_id, command_type)}"}
  end

  defp maybe_put_expected_version(input, nil), do: input

  defp maybe_put_expected_version(input, expected),
    do: Map.put(input, :expected_stream_version, expected)

  defp maybe_audit(%{command_type: command_type} = command, event_type, payload) do
    if Security.destructive_command?(command_type) do
      Security.append_destructive_audit(command, event_type, payload)
    else
      {:ok, []}
    end
  end

  defp task_status_event(command_type, payload, status) do
    case Map.get(payload, :task_id) do
      task_id when is_binary(task_id) and task_id != "" ->
        {:ok, "TaskUpdated", %{task_id: task_id, status: status}, "task:#{task_id}"}

      _ ->
        command_accepted(command_type, payload)
    end
  end

  defp required_binary(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  defp required_binary(_value, key), do: {:error, {:missing_or_invalid, key}}

  defp validate_task_status(nil), do: :ok

  defp validate_task_status(status) when is_binary(status) do
    if MapSet.member?(@task_statuses, status),
      do: :ok,
      else: {:error, {:invalid_task_status, status}}
  end

  defp validate_task_status(status), do: {:error, {:invalid_task_status, status}}

  defp handle_external_trigger(payload, metadata) do
    input = Map.put_new(payload, :correlation_id, Map.get(metadata, :correlation_id))

    with {:ok, result} <- IntegrationIngestion.ingest(input),
         {:ok, event} <- result_event(result) do
      {:ok, %{event: event, projection: ProjectionStore.snapshot(), integration: result}}
    end
  end

  defp result_event(%{ingestion: event}), do: {:ok, event}
  defp result_event(%{command: %{event: event}}), do: {:ok, event}

  defp result_event(%{existing: %{dedupe_key: dedupe_key}}) do
    case Enum.find(EventStore.all(), &(&1.stream_id == "integration:#{dedupe_key}")) do
      nil -> {:error, {:missing_integration_event, dedupe_key}}
      event -> {:ok, event}
    end
  end

  defp normalize_metadata(command) do
    metadata = normalize_payload(Map.get(command, :metadata, %{}))

    metadata
    |> Map.put_new(
      :correlation_id,
      Map.get(command, :correlation_id, Map.get(command, :command_id))
    )
    |> Map.put_new(:source, "node-cli-boundary")
    |> Map.put_new(:idempotency_key, Map.get(command, :command_id))
  end

  defp handle_planning_flow(payload, metadata) do
    input = Map.put_new(payload, :correlation_id, Map.get(metadata, :correlation_id))

    with {:ok, result} <- PlanningFlow.run(input) do
      {:ok, %{event: result.event, projection: ProjectionStore.snapshot(), planning: result}}
    end
  end

  defp handle_migration_import(payload, metadata) do
    input = Map.put_new(payload, :correlation_id, Map.get(metadata, :correlation_id))

    with {:ok, result} <- MigrationImporter.import(input) do
      {:ok, %{event: result.event, projection: ProjectionStore.snapshot(), migration: result}}
    end
  end

  defp planning_payload(command, command_type) do
    payload = external_trigger_payload(command)

    case command_type do
      "plan.prd" -> Map.put(payload, :kind, "prd")
      "plan.trd" -> Map.put(payload, :kind, "trd")
      _ -> payload
    end
  end

  defp migration_payload(command), do: external_trigger_payload(command)

  defp external_trigger_payload(command) do
    top_level =
      command
      |> normalize_payload()
      |> Map.drop([:command_id, :command_type, :correlation_id, :metadata])

    nested = normalize_payload(Map.get(command, :payload, %{}))

    if map_size(nested) == 0 do
      top_level
    else
      command
      |> Map.has_key?(:command_id)
      |> case do
        true -> top_level |> Map.drop([:payload]) |> Map.merge(nested)
        false -> Map.merge(top_level, nested)
      end
    end
  end

  defp external_command_id(command) do
    normalized = normalize_payload(command)

    Enum.find_value(
      [:command_id, :idempotency_key, :dedupe_key, :event_id, :external_id],
      fn key ->
        value = Map.get(normalized, key)
        if is_binary(value) and value != "", do: value
      end
    ) || "external-trigger:#{System.unique_integer([:positive])}"
  end

  # Generic command: filter whole wrapper to known top-level keys.
  defp normalize_payload(map) when is_map(map), do: filter_payload(map, known_keys())
  defp normalize_payload(_), do: %{}

  # worker.record: explicit allowlist of known top-level keys. No dynamic
  # atomization — prevents atom-exhaustion from arbitrary input keys.
  defp normalize_payload("worker.record", map) when is_map(map),
    do: filter_payload(map, known_worker_payload_keys())

  # Typed-command path: dispatch to worker.record or generic.
  defp normalize_payload(command_type, map) when is_map(map) do
    if command_type == "worker.record" do
      normalize_payload("worker.record", map)
    else
      filter_payload(map, known_keys())
    end
  end

  defp normalize_payload(_, _), do: %{}

  defp filter_payload(map, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case fetch_known_value(map, key) do
        :error -> acc
        {:ok, nil} -> acc
        {:ok, value} -> Map.put(acc, key, value)
      end
    end)
  end

  defp fetch_known_value(map, key) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.get(map, key)}
      Map.has_key?(map, Atom.to_string(key)) -> {:ok, Map.get(map, Atom.to_string(key))}
      true -> :error
    end
  end

  defp known_keys do
    [
      :author,
      :body,
      :command_id,
      :config,
      :correlation_id,
      :count,
      :create_prd_command,
      :dedupe_key,
      :default_branch,
      :dependencies,
      :description,
      :depends_on,
      :event_id,
      :event_type,
      :external_id,
      :fire_id,
      :flow_id,
      :external_link,
      :fingerprint,
      :health,
      :id,
      :inbox_messages,
      :input,
      :kind,
      :idempotency_key,
      :import_id,
      :import_index,
      :integration_event_type,
      :metadata,
      :migration_id,
      :name,
      :record_id,
      :record_type,
      :actor,
      :outcome,
      :occurred_at,
      :output_dir,
      :path,
      :payload,
      :phase_id,

      :plan_type,
      :planning_kind,
      :workflow,
      :planning_phase_id,
      :planning_run_id,
      :project_id,
      :projects,
      :repo,
      :run_id,
      :runs,
      :severity,
      :site,
      :source,
      :status,
      :task_id,
      :affected_stream_id,
      :projected_version,
      :actual_version,
      :task_type,
      :threshold,
      :tool_call_id,
      :tool_name,
      :trigger_id,
      :title,
      :trace_event_id,
      :priority,
      :task_type,
      :type,
      :transition_id,
      :url,
      :verdict,
      :final,
      :supersedes,
      :revision,
      :report_id,
      :artifact_path,
      :args,
      :allowed,
      :action,
      :current_phase,
      :base_branch,
      :branch_name,
      :head_sha,
      :branch,
      :base_ref,
      :merge_commit_sha,
      :merged_at,
      :phase_order,
      :pr_state,
      :old_base_branch,
      :new_base_branch,
      :phase,
      :pr_url,
      :pr_number,
      :association_id,
      :reason,
      :reason_type,
      :failure_type,
      :message,
      :workflows,
      :adapter,
      :compatibility_mode,
      :from_prd,
      :provider,
      :from,
      :to,
      :subject,
      :message_id,
      :worker_id,
      :sender_agent_type,
      :recipient_agent_type,
      :worker_supports_receiving,
      :sequence,
      :output,
      :artifact_paths,
      :report_paths,
      :exit_code,
      :worktree_path,
      :attempt,
      :failure_reason,
      :operation_id,
      :operation,
      :result,
      :error,
      :max_attempts,
      :retryable,
      :backend,
      :workspace_id,
      :project_path,
      :target,
      :stale_policy,
      :stale,
      :effects
    ]
  end

  # Top-level keys that worker.record payloads must preserve.
  # No dynamic atomization — prevents atom-exhaustion from arbitrary input.
  # Covers: start_phase, heartbeat, ingest_event, Tracker lifecycle events.
  defp known_worker_payload_keys do
    [
      # Core identity
      :run_id,
      :worker_id,
      :phase_id,
      :project_id,
      :task_id,
      # Sequence and timing
      :sequence,
      :observed_at,
      :exited_at,
      :detected_at,
      # Session / adapter
      :session_id,
      :adapter,
      :pid,
      # Env (WorkerStarted from start_phase)
      :prepared_env,
      :prepared_env_keys,
      :stripped_env_keys,
      :scoped_secret_keys,
      # Prompt
      :prompt_path,
      # Tools
      :tool_names,
      :tool_call_id,
      :tool_name,
      # Artifacts / reports
      :artifact_paths,
      :report_paths,
      # Status / output
      :status,
      :output,
      :message,
      :exit_code,
      # Attach / details (open nested maps — preserved as-is)
      :attach,
      :details,
      # Reason (Tracker: WorkerExited / WorkerUnresponsive)
      :reason,
      # Command envelope
      :event_type,
      :correlation_id,
      :command_id,
      :recipient_agent_type,
      :worker_supports_receiving,
      :affected_stream_id,
      :projected_version,
      :actual_version
    ]
  end
end
