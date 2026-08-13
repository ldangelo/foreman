defmodule ForemanServer.CommandGateway do
  @moduledoc """
  Sole in-process mutation gateway.

  Two entry points establish the trust boundary:

    * `dispatch_operator/2` — public operator commands. Currently allows
      only `project.register`, `task.create`, and `task.approve`. The
      command must carry `command_id`, `aggregate_id`, `type`, and a
      `payload` map. Returns `{:error, {:command_not_allowed, type}}`
      for any other type.
    * `dispatch_system/2` — trusted OTP automation (overwatch, recovery,
      supervisor, dispatcher, etc.). The `type` is unrestricted.

  Both functions delegate to `CommandRouter.dispatch/2` after validating
  or enriching the command. Only `CommandGateway` calls the router
  outside of test code; an architecture test enforces this invariant.

  ## Operator command enrichment

  `task.approve` is enriched by `ForemanServer.Workflow.Approval.prepare/1`
  before dispatch. The command ID becomes the deterministic `approval_id`
  embedded in `TaskApproved`, the server stamps `approved_at` once, and
  the persisted workflow snapshot is loaded atomically with the
  approval. Client-supplied `approval_id`, `approved_at`, `run_id`, or
  `workflow_snapshot` is rejected.

  ## Idempotency

  Commands carrying a `command_id` produce a deterministic event UUID.
  Repeating a committed operator command returns the same `event_spec`
  without appending a new event. The `dispatch_operator` enrichment
  path is short-circuited when the task projection already records the
  same `approval_id`, allowing retry after a transient network failure
  to succeed even if the assets have since changed.
  """

  alias ForemanServer.{CommandRouter, ProjectionStore, Telemetry}
  alias ForemanServer.Workflow.Approval
  alias ForemanServer.Workflow.ImplementationContext

  @allowed_operator_types ~w(project.register project.update project.archive task.create task.approve task.retry run.cancel)

  @type dispatch_result :: {:ok, map() | nil} | {:error, term()} | {:error, term(), term()}

  @doc """
  Dispatch a command originating from a public operator path.

  Required keys: `command_id`, `aggregate_id`, `type`, `payload`.
  Returns `{:error, {:command_not_allowed, type}}` when the type is
  not in `@allowed_operator_types`. Other invalid envelopes return
  `{:error, {:invalid_envelope, _}}` so callers can distinguish a
  malformed request from a domain error.
  """
  @spec dispatch_operator(map(), integer()) :: dispatch_result()
  def dispatch_operator(command, timeout \\ 5_000) when is_map(command) do
    with {:ok, normalized} <- normalize_operator_envelope(command),
         :ok <- validate_aggregate_id(normalized),
         {:ok, prepared} <- enrich_operator_command(normalized) do
      dispatch_and_emit_project_telemetry(prepared, timeout)
    end
  end

  @doc """
  Dispatch a command originating from trusted OTP automation.

  The router contract remains `{:ok, event_spec | nil} | {:error, _}`.
  Every new workflow command MUST carry a deterministic `command_id`
  so the actor can deduplicate retries by event UUID.
  """
  @spec dispatch_system(map(), integer()) :: dispatch_result()
  def dispatch_system(command, timeout \\ 5_000) when is_map(command) do
    dispatch_and_emit_project_telemetry(command, timeout)
  end

  # ---------------------------------------------------------------------------
  # Operator envelope
  # ---------------------------------------------------------------------------

  defp normalize_operator_envelope(command) do
    command_id = get_value(command, :command_id) || get_value(command, "command_id")
    aggregate_id = get_value(command, :aggregate_id) || get_value(command, "aggregate_id")
    type = get_value(command, :type) || get_value(command, "type")
    payload = get_value(command, :payload) || get_value(command, "payload") || %{}

    cond do
      not is_binary(command_id) or command_id == "" ->
        {:error, {:invalid_envelope, :missing_command_id}}

      not is_binary(aggregate_id) or aggregate_id == "" ->
        {:error, {:invalid_envelope, :missing_aggregate_id}}

      not is_binary(type) or type == "" ->
        {:error, {:invalid_envelope, :missing_type}}

      not is_map(payload) ->
        {:error, {:invalid_envelope, :invalid_payload}}

      type not in @allowed_operator_types ->
        {:error, {:command_not_allowed, type}}

      true ->
        normalized_payload = normalize_payload_keys(payload)

        {:ok,
         %{
           command_id: command_id,
           aggregate_id: aggregate_id,
           type: type,
           payload: normalized_payload
         }}
    end
  end

  defp validate_aggregate_id(%{
         type: "project.register",
         aggregate_id: aggregate_id,
         payload: payload
       }) do
    project_id = get_value(payload, :project_id) || get_value(payload, "project_id")

    cond do
      not is_binary(project_id) or project_id == "" ->
        {:error, {:invalid_envelope, :missing_project_id}}

      not is_binary(aggregate_id) or aggregate_id == "" ->
        {:error, {:invalid_envelope, :aggregate_id_mismatch}}

      aggregate_id != stream_id("project", project_id) ->
        {:error, {:invalid_envelope, :aggregate_id_mismatch}}

      true ->
        :ok
    end
  end

  defp validate_aggregate_id(%{
         type: "project.update",
         aggregate_id: aggregate_id,
         payload: payload
       }) do
    project_id = get_value(payload, :project_id) || get_value(payload, "project_id")

    cond do
      not is_binary(project_id) or project_id == "" ->
        {:error, {:invalid_envelope, :missing_project_id}}

      not is_binary(aggregate_id) or aggregate_id == "" ->
        {:error, {:invalid_envelope, :aggregate_id_mismatch}}

      aggregate_id != stream_id("project", project_id) ->
        {:error, {:invalid_envelope, :aggregate_id_mismatch}}

      true ->
        :ok
    end
  end

  defp validate_aggregate_id(%{
         type: "project.archive",
         aggregate_id: aggregate_id,
         payload: payload
       }) do
    project_id = get_value(payload, :project_id) || get_value(payload, "project_id")

    cond do
      not is_binary(project_id) or project_id == "" ->
        {:error, {:invalid_envelope, :missing_project_id}}

      not is_binary(aggregate_id) or aggregate_id == "" ->
        {:error, {:invalid_envelope, :aggregate_id_mismatch}}

      aggregate_id != stream_id("project", project_id) ->
        {:error, {:invalid_envelope, :aggregate_id_mismatch}}

      true ->
        :ok
    end
  end

  defp validate_aggregate_id(%{type: "task.create", aggregate_id: aggregate_id, payload: payload}) do
    external_id = Map.get(payload, :external_id)
    task_id = get_value(payload, :task_id) || get_value(payload, "task_id")
    project_id = get_value(payload, :project_id) || get_value(payload, "project_id")

    cond do
      external_id != nil ->
        {:error, :external_id_not_allowed_via_operator}

      not is_binary(task_id) or task_id == "" ->
        {:error, {:invalid_envelope, :missing_task_id}}

      not is_binary(aggregate_id) or aggregate_id == "" ->
        {:error, {:invalid_envelope, :aggregate_id_mismatch}}

      aggregate_id != stream_id("task", task_id) ->
        {:error, {:invalid_envelope, :aggregate_id_mismatch}}

      is_binary(project_id) and project_id != "" ->
        case ProjectionStore.project_projection(project_id) do
          nil -> {:error, {:project_not_found, project_id}}
          %{archived?: true} -> {:error, {:project_archived, project_id}}
          _ -> :ok
        end

      true ->
        {:error, {:invalid_envelope, :missing_project_id}}
    end
  end

  defp validate_aggregate_id(%{
         type: "task.approve",
         aggregate_id: aggregate_id,
         payload: payload
       }) do
    task_id = get_value(payload, :task_id) || get_value(payload, "task_id")

    cond do
      not is_binary(task_id) or task_id == "" ->
        {:error, {:invalid_envelope, :missing_task_id}}

      not is_binary(aggregate_id) or aggregate_id == "" ->
        {:error, {:invalid_envelope, :aggregate_id_mismatch}}

      aggregate_id != stream_id("task", task_id) ->
        {:error, {:invalid_envelope, :aggregate_id_mismatch}}

      reserved_approval_field?(payload) ->
        {:error, {:invalid_envelope, :reserved_approval_field}}

      true ->
        case ProjectionStore.task_projection(task_id) do
          nil -> {:error, {:task_not_found, task_id}}
          _ -> :ok
        end
    end
  end

  defp validate_aggregate_id(%{type: "task.retry", aggregate_id: aggregate_id, payload: payload}) do
    task_id = get_value(payload, :task_id) || get_value(payload, "task_id")

    cond do
      not is_binary(task_id) or task_id == "" ->
        {:error, {:invalid_envelope, :missing_task_id}}

      not is_binary(aggregate_id) or aggregate_id == "" ->
        {:error, {:invalid_envelope, :aggregate_id_mismatch}}

      aggregate_id != stream_id("task", task_id) ->
        {:error, {:invalid_envelope, :aggregate_id_mismatch}}

      true ->
        :ok
    end
  end

  defp validate_aggregate_id(%{type: "run.cancel", aggregate_id: aggregate_id, payload: payload}) do
    run_id = get_value(payload, :run_id) || get_value(payload, "run_id")

    cond do
      not is_binary(run_id) or run_id == "" ->
        {:error, {:invalid_envelope, :missing_run_id}}

      not is_binary(aggregate_id) or aggregate_id == "" ->
        {:error, {:invalid_envelope, :aggregate_id_mismatch}}

      aggregate_id != stream_id("run", run_id) ->
        {:error, {:invalid_envelope, :aggregate_id_mismatch}}

      true ->
        :ok
    end
  end

  @reserved_approval_fields ~w(approval_id approved_at run_id workflow_snapshot)a
  defp reserved_approval_field?(payload) do
    Enum.any?(@reserved_approval_fields, fn key ->
      get_value(payload, key) not in [nil, ""]
    end)
  end

  # Project the trusted `workflow_type` / `task_type` from the task
  # projection into the payload. Projection wins over any operator
  # value because the operator's authority is task creation, not task
  # reclassification. Used by `enrich_approval_via_workflow/2` so
  # `Approval.prepare/2` selects the manifest the task was registered
  # for rather than whatever the operator happens to send at approval.
  defp maybe_put_from_projection(payload, projection, key) do
    case Map.get(projection, key) do
      nil -> payload
      value -> Map.put(payload, key, value)
    end
  end

  # Canonical stream ID for a domain entity. Mirrors the convention used by
  # `Aggregate.Aggregator` and the existing actor tests (`run:abc`,
  # `task:abc`, `project:abc`). Any caller that supplies an `aggregate_id`
  # not matching `prefix:id` is rejected before dispatch.
  defp stream_id(prefix, id) when is_binary(prefix) and is_binary(id),
    do: prefix <> ":" <> id

  defp enrich_operator_command(%{type: "task.approve"} = command) do
    task_id = get_value(command.payload, :task_id) || get_value(command.payload, "task_id")

    case ProjectionStore.task_projection(task_id) do
      nil ->
        {:error, {:task_not_found, task_id}}

      task when is_map(task) ->
        approval_id = Map.get(task, :approval_id)
        # Idempotent retry: rebuild the original enriched payload from
        # the projection so the operator can re-send the same command_id
        # even after workflow assets have changed.
        if approval_id == Map.get(command, :command_id) do
          rebuilt_payload = rebuild_approval_payload(task, command.payload)
          {:ok, %{command | payload: rebuilt_payload}}
        else
          enrich_approval_via_workflow(command, task)
        end

      _ ->
        enrich_approval_via_workflow(command, %{})
    end
  end

  defp enrich_approval_via_workflow(
         %{command_id: command_id, payload: payload} = command,
         task_projection
       ) do
    approval_id = command_id
    approved_at = DateTime.utc_now() |> DateTime.to_iso8601()

    # workflow_type and task_type are read from the task projection
    # (single source of truth); an operator-supplied value is ignored
    # so a client cannot route approval to a workflow the task was
    # never registered for. workflow_type is copied first so
    # `Approval.prepare/2`'s `workflow_type || task_type` precedence
    # selects the implement-trd / implement-trd-beads manifest when
    # the task was registered with one, even if task_type is something
    # generic like "implement".
    payload_with_type =
      payload
      |> maybe_put_from_projection(task_projection, :workflow_type)
      |> maybe_put_from_projection(task_projection, :task_type)

    with {:ok, prepared} <-
           Approval.prepare(payload_with_type, approval_id: approval_id),
         {:ok, snapshot} <- freeze_implementation_context(task_projection, prepared) do
      enriched_payload =
        payload
        |> Map.put(:approval_id, prepared.approval_id)
        |> Map.put(:run_id, prepared.run_id)
        |> Map.put(:workflow_snapshot, snapshot)
        |> Map.put(:approved_at, approved_at)
        |> Map.put(:workflow_name, prepared.workflow_name)
        |> Map.put(:workflow_digest, prepared.workflow_digest)

      {:ok, %{command | payload: enriched_payload}}
    end
  end

  # For tasks registered with a workflow that requires a frozen
  # implementation context (`implement-trd` or `implement-trd-beads`),
  # build the context from the trusted task projection and persist it
  # inside `workflow_snapshot.implementation`. The nested map is the
  # authoritative store; it is replayed via `TaskApproved` and read
  # back on idempotent re-approval.
  #
  # All other tasks keep their existing approval contract; the
  # implementation context is unbuilt and `workflow_snapshot` is passed
  # through unchanged.
  defp freeze_implementation_context(task_projection, prepared) do
    workflow_type = get_value(task_projection, :workflow_type)

    if workflow_type in ["implement-trd", "implement-trd-beads"] do
      build =
        ImplementationContext.build(%{
          project_id: get_value(task_projection, :project_id),
          workflow_type: workflow_type,
          trd_path: get_value(task_projection, :trd_path)
        })

      with {:ok, context} <- build do
        {:ok,
         Map.put(
           prepared.workflow_snapshot || %{},
           "implementation",
           ImplementationContext.to_payload(context)
         )}
      end
    else
      {:ok, prepared.workflow_snapshot || %{}}
    end
  end

  defp enrich_operator_command(%{type: "task.create"} = command) do
    enriched =
      command.payload
      |> Map.put_new(:status, "open")
      |> Map.put_new(:dependencies, [])
      |> Map.put_new(:source, nil)
      |> Map.put_new(:external_id, nil)
      |> Map.put_new(:external_link, nil)
      |> Map.put_new(:dedupe_key, nil)
      |> Map.put_new(:integration_event_type, nil)
      |> Map.put_new(:planning_run_id, nil)
      |> Map.put_new(:planning_kind, nil)
      |> Map.put_new(:planning_phase_id, nil)
      |> Map.put_new(:trace_event_id, nil)

    {:ok, %{command | payload: enriched}}
  end

  defp enrich_operator_command(%{type: "task.retry"} = command) do
    task_id =
      get_value(command.payload, :task_id) || get_value(command.payload, "task_id")

    cond do
      not is_binary(task_id) or task_id == "" ->
        {:error, {:invalid_envelope, :missing_task_id}}

      true ->
        enrich_task_retry_with_bound_run(command, task_id)
    end
  end

  # `task.retry` is the unconditional operator remediation path. It MUST
  # only commit when the task is bound to a run that is currently
  # terminal — so we look up the bound run projection through the
  # gateway (single trusted boundary), refuse to enrich otherwise, and
  # attach the terminal evidence to the payload. The aggregate then
  # validates that the attached `acknowledged_run_id` matches its own
  # currently-bound run before emitting `TaskRetried`.
  #
  # The Dispatcher subscriber path (run.cancel → task.run_terminated)
  # remains in place for newly observed terminal events; the aggregate
  # also accepts that path. Both paths converge on the same payload
  # shape, so the aggregate needs only one precondition:
  # `payload.acknowledged_run_id == state.run_id`.
  defp enrich_task_retry_with_bound_run(command, task_id) do
    task = ProjectionStore.task_projection(task_id)

    cond do
      task == nil ->
        {:error, {:task_not_found, task_id}}

      true ->
        enrich_task_retry_with_run_projection(command, task)
    end
  end

  defp enrich_task_retry_with_run_projection(command, task) do
    bound_run_id = Map.get(task, :run_id)

    cond do
      not is_binary(bound_run_id) or bound_run_id == "" ->
        {:error, {:missing_or_invalid, :run_id}}

      true ->
        run = ProjectionStore.run(bound_run_id)

        cond do
          run == nil ->
            {:error, {:run_not_found, bound_run_id}}

          Map.get(run, :task_id) != Map.get(task, :task_id) ->
            {:error,
             {:run_task_binding_drift, bound_run_id, Map.get(run, :task_id),
              Map.get(task, :task_id)}}

          Map.get(run, :terminal?) != true ->
            {:error, {:run_not_terminal, Map.get(run, :status)}}

          true ->
            attach_retry_evidence(command, run)
        end
    end
  end

  defp attach_retry_evidence(command, run) do
    acknowledged_at =
      case Map.get(run, :last_event_at_ms) do
        ms when is_integer(ms) ->
          DateTime.from_unix!(ms, :millisecond) |> DateTime.to_iso8601()

        _ ->
          DateTime.utc_now() |> DateTime.to_iso8601()
      end

    enriched_payload =
      command.payload
      |> Map.put(:acknowledged_run_id, Map.get(run, :run_id))
      |> Map.put(:acknowledged_at, acknowledged_at)
      |> Map.put(:run_terminal_reason, Map.get(run, :failure_reason))

    {:ok, %{command | payload: enriched_payload}}
  end

  defp enrich_operator_command(command), do: {:ok, command}

  defp dispatch_and_emit_project_telemetry(command, timeout) do
    started_at = System.monotonic_time()
    result = CommandRouter.dispatch(command, timeout)
    emit_project_telemetry(command, result, started_at)
    result
  end

  defp emit_project_telemetry(command, result, started_at) do
    case project_telemetry_fun(get_value(command, :type) || get_value(command, "type")) do
      nil ->
        :ok

      telemetry_fun ->
        metadata =
          %{
            project_id: project_id(command),
            outcome: telemetry_outcome(result)
          }
          |> maybe_put_project_error_metadata(result)

        apply(Telemetry, telemetry_fun, [duration_ms_since(started_at), metadata])
    end
  end

  defp project_telemetry_fun("project.register"), do: :project_register
  defp project_telemetry_fun("project.update"), do: :project_update
  defp project_telemetry_fun("project.archive"), do: :project_archive
  defp project_telemetry_fun(_), do: nil

  defp project_id(command) do
    payload = get_value(command, :payload) || get_value(command, "payload") || %{}

    case get_value(payload, :project_id) || get_value(payload, "project_id") do
      project_id when is_binary(project_id) and project_id != "" ->
        project_id

      _ ->
        project_id_from_aggregate_id(
          get_value(command, :aggregate_id) || get_value(command, "aggregate_id")
        )
    end
  end

  defp project_id_from_aggregate_id("project:" <> project_id), do: project_id
  defp project_id_from_aggregate_id(_), do: nil

  defp telemetry_outcome({:ok, _}), do: :ok
  defp telemetry_outcome({:error, _}), do: :error
  defp telemetry_outcome({:error, _, _}), do: :error

  defp maybe_put_project_error_metadata(metadata, {:ok, _}), do: metadata

  defp maybe_put_project_error_metadata(metadata, {:error, reason}) do
    Map.merge(metadata, project_error_metadata(reason))
  end

  defp maybe_put_project_error_metadata(metadata, {:error, reason, detail}) do
    Map.merge(metadata, project_error_metadata({reason, detail}))
  end

  defp project_error_metadata({:already_exists, :project, _}) do
    %{code: "already_exists", retryable: false}
  end

  defp project_error_metadata({:project_has_active_runs, _run_ids}) do
    %{code: "project_has_active_runs", retryable: false}
  end

  defp project_error_metadata({:wrong_expected_version, _current_version}) do
    %{code: "version_conflict", retryable: false}
  end

  defp project_error_metadata(:project_not_found),
    do: %{code: "project_not_found", retryable: false}

  defp project_error_metadata({:project_not_found, _}),
    do: %{code: "project_not_found", retryable: false}

  defp project_error_metadata(:project_archived),
    do: %{code: "project_archived", retryable: false}

  defp project_error_metadata({code, _detail}) when is_atom(code) do
    %{code: Atom.to_string(code), retryable: false}
  end

  defp project_error_metadata({code, _, _}) when is_atom(code) do
    %{code: Atom.to_string(code), retryable: false}
  end

  defp project_error_metadata(code) when is_atom(code) do
    %{code: Atom.to_string(code), retryable: false}
  end

  defp project_error_metadata(_), do: %{code: "unknown_error", retryable: false}

  defp duration_ms_since(started_at) do
    System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)
  end

  defp rebuild_approval_payload(task, original_payload) do
    approved_by =
      get_value(original_payload, :approved_by) || get_value(original_payload, "approved_by")

    snapshot = Map.get(task, :workflow_snapshot) || %{}
    run_id = Map.get(task, :run_id)

    base = %{
      task_id: get_value(original_payload, :task_id) || get_value(original_payload, "task_id"),
      approved_by: approved_by,
      approval_id: task.approval_id,
      approved_at: Map.get(task, :approved_at),
      run_id: run_id,
      workflow_snapshot: snapshot
    }

    Enum.reduce(base, %{}, fn {k, v}, acc ->
      if is_nil(v), do: acc, else: Map.put(acc, k, v)
    end)
  end

  # Public payload keys (operator commands) must be limited to a known
  # set per type. Atomize only those keys, leave unknown values alone.
  defp normalize_payload_keys(payload) when is_map(payload) do
    Enum.reduce(payload, %{}, fn {k, v}, acc ->
      atom_key =
        case k do
          atom when is_atom(atom) -> atom
          binary when is_binary(binary) -> safe_to_existing_atom(binary)
          _ -> k
        end

      Map.put(acc, atom_key, v)
    end)
  end

  defp safe_to_existing_atom("") do
    ""
  end

  defp safe_to_existing_atom(binary) when is_binary(binary) do
    String.to_existing_atom(binary)
  rescue
    ArgumentError -> binary
  end

  defp get_value(map, key) when is_map(map), do: Map.get(map, key)
end
