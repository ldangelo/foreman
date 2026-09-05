defmodule ForemanServer.CommandGateway do
  @moduledoc """
  Sole in-process mutation gateway.

  Two entry points establish the trust boundary:

    * `dispatch_operator/2` — public operator commands. Currently allows
      `project.register`, `project.update`, `project.archive`,
      `project.reactivate`, `task.create`, `task.approve`, `task.retry`,
      `run.cancel`, `run.remove`, and `run.reset`. The command must carry
      `command_id`, `type`, and a `payload` map.
      `aggregate_id` is required except for `task.create` in no-id mode
      (where both `aggregate_id` and `payload.task_id` are absent); in that
      case the gateway resolves the backend issue ID automatically.
      Returns `{:error, {:command_not_allowed, type}}`
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
  alias ForemanServer.TaskProvider.Registry
  alias ForemanServer.Workflow.Approval
  alias ForemanServer.Workflow.ImplementationContext

  @allowed_operator_types ~w(project.register project.update project.archive project.reactivate task.create task.approve task.retry task.update run.cancel run.remove run.reset)

  @type dispatch_result :: {:ok, map() | nil} | {:error, term()} | {:error, term(), term()}

  @doc """
  Dispatch a command originating from a public operator path.

  Required keys: `command_id`, `type`, `payload`.  `aggregate_id` is
  required except for `task.create` in no-id mode (both `aggregate_id`
  and `payload.task_id` absent), where the gateway resolves the backend
  issue ID and enriches the command automatically.
  Returns `{:error, {:command_not_allowed, type}}` when the type is
  not in `@allowed_operator_types`. Other invalid envelopes return
  `{:error, {:invalid_envelope, _}}` so callers can distinguish a
  malformed request from a domain error.
  """
  @spec dispatch_operator(map(), integer()) :: dispatch_result()
  def dispatch_operator(command, timeout \\ 5_000) when is_map(command) do
    with {:ok, normalized} <- normalize_operator_envelope(command),
         {:ok, prepared} <- prepare_operator_command(normalized),
         :ok <- validate_aggregate_id(prepared),
         {:ok, enriched} <- enrich_operator_command(prepared) do
      case dispatch_and_emit_project_telemetry(enriched, timeout) do
        {:ok, _} = result -> maybe_auto_approve(enriched, result, timeout)
        other -> other
      end
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

    payload_task_id =
      if is_map(payload) do
        get_value(payload, :task_id) || get_value(payload, "task_id")
      else
        nil
      end

    cond do
      not is_binary(command_id) or command_id == "" ->
        {:error, {:invalid_envelope, :missing_command_id}}

      not is_binary(type) or type == "" ->
        {:error, {:invalid_envelope, :missing_type}}

      not is_map(payload) ->
        {:error, {:invalid_envelope, :invalid_payload}}

      type not in @allowed_operator_types ->
        {:error, {:command_not_allowed, type}}

      type == "task.create" and is_map(payload) and
        (aggregate_id == nil or aggregate_id == "") and
          (is_nil(payload_task_id) or payload_task_id == "") ->
        {:ok,
         %{
           command_id: command_id,
           aggregate_id: nil,
           type: type,
           payload: normalize_payload_keys(payload)
         }}

      not is_binary(aggregate_id) or aggregate_id == "" ->
        {:error, {:invalid_envelope, :missing_aggregate_id}}

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

  defp validate_aggregate_id(%{
         type: "project.reactivate",
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
    gateway_resolved? = Map.get(payload, :gateway_resolved_external_id?) == true

    cond do
      external_id != nil and not gateway_resolved? ->
        {:error, :external_id_not_allowed_via_operator}

      gateway_resolved? and
          (not is_binary(task_id) or task_id == "" or external_id != task_id) ->
        {:error, {:invalid_envelope, :gateway_resolved_external_id_mismatch}}

      not gateway_resolved? and (not is_binary(task_id) or task_id == "") ->
        {:error, {:invalid_envelope, :missing_task_id}}

      not is_binary(aggregate_id) or aggregate_id == "" ->
        {:error, {:invalid_envelope, :aggregate_id_mismatch}}

      aggregate_id != stream_id("task", task_id) ->
        {:error, {:invalid_envelope, :aggregate_id_mismatch}}

      # A non-list `dependencies` is refused at the boundary rather than
      # normalized, because every downstream default turns it into "no
      # dependencies" — the read model used `|| []`, which per AGENTS.md §5.4b
      # collapses `false` and `nil` alike and loses the signal. A task created
      # with `dependencies: false` then approved and dispatched with no checks
      # at all, which is precisely the inertness the guard exists to close,
      # re-entered through malformed input. Absent stays absent; anything
      # present must be a list (§5.3: absent and malformed are different).
      not valid_dependencies?(get_value(payload, :dependencies)) ->
        {:error, {:invalid_envelope, :invalid_dependencies}}

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

  defp validate_aggregate_id(
         %{
           type: "task.approve",
           aggregate_id: aggregate_id,
           payload: payload
         } = command
       ) do
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
          task -> require_dependencies_satisfied(task, command)
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

  defp validate_aggregate_id(%{type: "task.update", aggregate_id: aggregate_id, payload: payload}) do
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

  defp validate_aggregate_id(%{type: type, aggregate_id: aggregate_id, payload: payload})
       when type in ["run.cancel", "run.remove", "run.reset"] do
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

  defp validate_aggregate_id(%{
         type: "run.report_stall",
         aggregate_id: aggregate_id,
         payload: payload
       }) do
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

  # Approval is the transition that triggers dispatch, so it is the only place a
  # declared dependency can still change the outcome. `task.create` accepted
  # `dependencies`, the aggregate stored them, and `TaskCreated` carried them —
  # but `Task.require_dispatchable/1` reads only `status`, `run_id` and
  # `approval_id`, so a task declaring dependencies dispatched immediately
  # regardless of whether any of them had finished. The field was inert for its
  # entire life while reading as a working feature.
  #
  # The guard lives here rather than in the aggregate because it is inherently
  # cross-aggregate: `Task` can only see its OWN state, and asking it about other
  # tasks would either break the aggregate boundary or require replaying foreign
  # streams. `ProjectionStore` is the read model built for exactly this, and the
  # `task.create` clause above already reads `project_projection/1` the same way.
  #
  # Deliberately NOT a dependency DAG: no ordering, no cycle detection, no
  # automatic dispatch when the last dependency closes. This refuses an approval
  # that cannot honour its own declaration, and nothing more. An operator
  # re-approves once the dependencies are closed.
  #
  # An idempotent approval RETRY bypasses the guard entirely. The module
  # docstring promises a re-sent `command_id` succeeds "even if the assets have
  # since changed", and `enrich_operator_command/1` honours that by rebuilding
  # the original payload from the projection when `approval_id == command_id`.
  # A dependency's status is one of those assets: approve while a dependency is
  # `closed`, let it be `task.retry`'d back to `open`, then re-send the original
  # command after a network failure, and a guard that ran first would answer
  # `:task_dependencies_unsatisfied` where the operator had already been told
  # the approval succeeded. Validating here cannot re-decide a committed
  # approval — the dispatch is deduplicated by `command_id` downstream and
  # emits no second event — so refusing would report a failure that did not
  # happen. The guard governs NEW approvals only.
  defp require_dependencies_satisfied(task, command) do
    if Map.get(task, :approval_id) == Map.get(command, :command_id) do
      :ok
    else
      case Map.get(task, :dependencies) do
        nil ->
          :ok

        dependency_ids when is_list(dependency_ids) ->
          case unsatisfied_dependencies(dependency_ids) do
            [] -> :ok
            unsatisfied -> {:error, {:task_dependencies_unsatisfied, unsatisfied}}
          end

        malformed ->
          # `task.create` now refuses a non-list, but events written before that
          # validation existed are already in the store, and a read model cannot
          # raise on replay — `ProjectionStore.init/1` rebuilds from the event
          # log, so raising here would turn one bad historical event into a boot
          # failure for the whole application (the `WorkerStdout` lesson in
          # AGENTS.md, Durable Run Logs). Refusing the APPROVAL instead keeps the
          # blast radius at the one task and still cannot dispatch unchecked.
          {:error, {:task_dependencies_malformed, malformed}}
      end
    end
  end

  # Absent is a valid declaration; present-but-not-a-list is not. Deliberately
  # not `is_list(x) or is_nil(x)` folded into a default — see the §5.4b note at
  # the `task.create` clause on why `|| []` is the wrong shape here.
  defp valid_dependencies?(nil), do: true
  defp valid_dependencies?(value), do: is_list(value)

  # Each unsatisfied dependency is reported with WHY, because "absent" and
  # "present but unfinished" need different operator actions (AGENTS.md §5.3):
  # a missing id is a typo or a task never created, while `in_progress` just
  # means wait. `closed` is the only success status — `failed` is terminal but
  # did not produce the work this task depends on, so approving on it would
  # dispatch against a dependency that never delivered.
  defp unsatisfied_dependencies(dependency_ids) do
    dependency_ids
    |> Enum.reduce([], fn dependency_id, acc ->
      # A malformed id is reported, never skipped. Dropping it would make
      # `dependencies: [nil]` approve as though nothing were declared — the same
      # silent-inertness class this whole guard exists to close.
      if is_binary(dependency_id) and dependency_id != "" do
        case ProjectionStore.task_projection(dependency_id) do
          nil -> [{dependency_id, :not_found} | acc]
          %{status: "closed"} -> acc
          %{status: status} -> [{dependency_id, status} | acc]
        end
      else
        [{dependency_id, :malformed} | acc]
      end
    end)
    |> Enum.reverse()
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

  defp enrich_operator_command(%{type: "task.create"} = command) do
    enriched =
      command.payload
      |> Map.put_new(:status, "open")
      |> Map.put_new(:dependencies, [])
      |> Map.put_new(:priority, 0)
      |> Map.put_new(:source, nil)
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

  defp enrich_operator_command(command), do: {:ok, command}
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
      |> maybe_put_from_projection(task_projection, :prompt)

    with {:ok, prepared} <-
           Approval.prepare(payload_with_type, approval_id: approval_id),
         {:ok, snapshot} <- freeze_implementation_context(task_projection, prepared) do
      rendered_snapshot = render_strict_fields(snapshot)

      enriched_payload =
        payload
        |> Map.put(:approval_id, prepared.approval_id)
        |> Map.put(:run_id, prepared.run_id)
        |> Map.put(:workflow_snapshot, rendered_snapshot)
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

  # Strict approval rendering per TRD Decision 11.
  #
  # Materialize the snapshot's `phases[*].command` and the workflow-level
  # `worktree.base` from the frozen implementation context so the human review
  # surfaces the exact command and base ref that Foreman will execute. Branch
  # and path retain runtime placeholders (`{run_id}`) until run IDs exist; those
  # are resolved at execution time by `RunExecutor`.
  #
  # `worktree.base` moved with the block itself: it used to be rendered per
  # phase (`phases[*].worktree.base`) because each phase declared its own
  # worktree. A run has exactly one worktree, so there is one base to freeze.
  #
  # Only the `implement-trd` and `implement-trd-beads` workflows carry
  # the `implementation` overlay. All other workflows pass through
  # unchanged because their command strings have no placeholders to
  # substitute.
  #
  # The `TaskApproved` event payload is JSON-encoded for EventStore
  # persistence, so the canonical persisted form is string-keyed. The
  # snapshot also carries atom-keyed duplicates for in-process use
  # (`Catalog.resolve_workflow/3` seeds atom keys on top of the
  # YAML-parsed string keys; `Map.merge` in
  # `Approval.resolve_workflow_snapshot/2` preserves both). If we
  # rendered both key types, the resulting JSON would carry two
  # entries per field (e.g. `{"command": "...", "command": "..."}`),
  # which is invalid JSON and silently drops one entry per encoder.
  # We therefore write the canonical string key and delete the atom
  # twin. Consumers like `RunExecutor` that read atom keys must be
  # updated to read string keys (or accept both) — see the regression
  # test in `command_gateway_test.exs`.
  def render_strict_fields(snapshot) when is_map(snapshot) do
    impl = get_value(snapshot, "implementation")
    input = normalize_input_for_render(get_value(snapshot, "input"))

    cond do
      is_map(impl) and impl != %{} ->
        snapshot
        |> render_phases(impl, input)
        |> render_worktree_base(impl)

      is_map(input) and input != %{} ->
        render_phases(snapshot, nil, input)

      true ->
        snapshot
    end
  end

  defp render_phases(snapshot, impl, input) do
    phases = get_value(snapshot, "phases") || get_value(snapshot, :phases) || []
    rendered = Enum.map(phases, fn phase -> render_command(phase, impl, input) end)
    put_canonical(snapshot, "phases", :phases, rendered)
  end

  # Derive `input.prompt_argument` as JSON-encoded `input.prompt` so the
  # command template can safely embed the prompt as a single quoted
  # argument (TRD-020).  When `prompt_argument` is already present it is
  # preserved verbatim.
  defp normalize_input_for_render(input) when is_map(input) do
    prompt = get_value(input, "prompt")

    if is_binary(prompt) and get_value(input, "prompt_argument") == nil do
      Map.put(input, "prompt_argument", Jason.encode!(prompt))
    else
      input
    end
  end

  defp normalize_input_for_render(input), do: input

  def render_command(phase, impl, input) do
    template = get_value(phase, "command") || get_value(phase, :command)

    case template do
      value when is_binary(value) ->
        rendered =
          value
          |> substitute(
            "{{input.prompt}}",
            input && get_value(input, "prompt")
          )
          |> substitute(
            "{{input.prompt_argument}}",
            input && get_value(input, "prompt_argument")
          )
          |> substitute(
            "{{implementation.trd_path_argument}}",
            impl && get_value(impl, "trd_path_argument")
          )
          |> substitute(
            "{{implementation.source_revision}}",
            impl && get_value(impl, "source_revision")
          )

        put_canonical(phase, "command", :command, rendered)

      _ ->
        phase
    end
  end

  # Freezes the workflow-level `worktree.base`. The block is read off the
  # snapshot, beside `phases`.
  defp render_worktree_base(snapshot, impl) do
    case get_value(snapshot, "worktree") || get_value(snapshot, :worktree) do
      block when is_map(block) ->
        case get_value(block, "base") || get_value(block, :base) do
          value when is_binary(value) ->
            rendered =
              substitute(
                value,
                "{{implementation.source_revision}}",
                get_value(impl, "source_revision")
              )

            rendered_block = put_canonical(block, "base", :base, rendered)
            put_canonical(snapshot, "worktree", :worktree, rendered_block)

          _ ->
            snapshot
        end

      _ ->
        snapshot
    end
  end

  # Write `value` under `string_key` and delete the same-name atom
  # twin so that JSON encoding cannot produce duplicate fields.
  # `delete_only_existing` ensures we don't add `nil` keys; if the
  # atom twin is absent we leave the map alone.
  defp put_canonical(map, string_key, atom_key, value) do
    map
    |> maybe_delete_key(atom_key)
    |> Map.put(string_key, value)
  end

  defp maybe_delete_key(map, key) do
    case Map.fetch(map, key) do
      {:ok, _} -> Map.delete(map, key)
      :error -> map
    end
  end

  defp substitute(string, placeholder, value) when is_binary(string) and is_binary(placeholder) do
    case value do
      nil -> string
      "" -> string
      v when is_binary(v) -> String.replace(string, placeholder, v)
    end
  end

  # Pre-validation step for operator commands.
  #
  # For `task.create` with no `aggregate_id` (no-id flow): calls the configured
  # task provider to create the backend issue, then sets `payload.task_id`,
  # `payload.external_id`, and `aggregate_id` to the returned `Issue.id`.
  # The `gateway_resolved?` marker allows `validate_aggregate_id` to permit
  # this gateway-set `external_id` while still rejecting client-supplied values.
  #
  # All other commands pass through unchanged.
  defp prepare_operator_command(%{type: "task.create", aggregate_id: nil} = command) do
    payload = command.payload
    project_id = get_value(payload, :project_id) || get_value(payload, "project_id")

    cond do
      not is_binary(project_id) or project_id == "" ->
        {:error, {:invalid_envelope, :missing_project_id}}

      Map.get(payload, :external_id) != nil ->
        {:error, :external_id_not_allowed_via_operator}

      true ->
        project = ProjectionStore.project_projection(project_id)

        cond do
          project == nil ->
            {:error, {:project_not_found, project_id}}

          Map.get(project, :archived?) == true ->
            {:error, {:project_archived, project_id}}

          true ->
            with {:ok, provider} <- Registry.route(:create, %{project_id: project_id}) do
              attrs = %{
                task_id: command.command_id,
                command_id: command.command_id,
                title: get_value(payload, :title),
                description: get_value(payload, :description),
                priority: get_value(payload, :priority) || 0,
                task_type: get_value(payload, :task_type) || get_value(payload, :type),
                dedupe_key:
                  case get_value(payload, :dedupe_key) do
                    k when is_binary(k) and k != "" -> k
                    _ -> command.command_id
                  end
              }

              case provider.create(project_id, attrs) do
                {:ok, %{id: issue_id}} when is_binary(issue_id) ->
                  enriched_payload =
                    payload
                    |> Map.put(:task_id, issue_id)
                    |> Map.put(:external_id, issue_id)
                    |> Map.put(:gateway_resolved_external_id?, true)

                  {:ok, %{command | aggregate_id: "task:#{issue_id}", payload: enriched_payload}}

                {:error, reason} ->
                  {:error, reason}
              end
            end
        end
    end
  end

  defp prepare_operator_command(command), do: {:ok, command}

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

  # `auto_approve` lets an ad-hoc `task.create` caller dispatch in one
  # round trip: on a successful create, immediately issue the matching
  # `task.approve` and return ITS result to the original caller, so the
  # HTTP response carries `approval_id`/`run_id` the same way `work.submit`
  # did. The approval command_id is derived from the create command_id so a
  # retried `task.create` cannot mint a second approval — the existing
  # idempotent-retry branch in `enrich_operator_command/1` keys on
  # `approval_id == command_id` and rebuilds instead of re-approving.
  # `auto_approve` itself is never forwarded past this function: `task.create`
  # builds its `TaskCreated` payload explicitly field-by-field and ignores it.
  defp maybe_auto_approve(
         %{type: "task.create", command_id: command_id, payload: payload},
         create_result,
         timeout
       ) do
    if truthy?(get_value(payload, :auto_approve)) do
      task_id = get_value(payload, :task_id) || get_value(payload, "task_id")

      approved_by =
        case get_value(payload, :approved_by) do
          value when is_binary(value) and value != "" -> value
          _ -> "auto_approve"
        end

      approve_command = %{
        command_id: "#{command_id}:auto-approve",
        type: "task.approve",
        aggregate_id: "task:#{task_id}",
        payload: %{task_id: task_id, approved_by: approved_by}
      }

      dispatch_operator(approve_command, timeout)
    else
      create_result
    end
  end

  defp maybe_auto_approve(_command, result, _timeout), do: result

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

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
