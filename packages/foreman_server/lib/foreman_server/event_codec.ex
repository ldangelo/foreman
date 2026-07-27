defmodule ForemanServer.EventCodec do
  @moduledoc """
  Dual-read decoder for authoritative domain events.

  All event reads route through `decode!/2` to enforce a single contract.
  The `event_type` string is always provided explicitly as the first argument,
  enabling the codec to reject a typed struct whose module does not match the
  expected event type — the core enforcement of TRD-003 AC3.

  ## Typed struct pass-through
      decode!("RunStarted", %ForemanServer.Events.RunStarted{run_id: "abc", task_id: "xyz"})
  Returns the struct unchanged when the module name corresponds to `event_type`.
  Raises `ArgumentError` when the module name does not match.

  ## Map with `__struct__`
      decode!("RunStarted", %{"__struct__" => "ForemanServer.Events.RunStarted", "run_id" => "abc", ...})
  Validates the module matches `event_type`, then validates all keys, raises
  `KeyError` on unknown keys, and rebuilds the typed struct.

  ## Legacy map (no `__struct__`)
      decode!("run_started", %{"type" => "run_started", "run_id" => "abc", ...})
  Uses the `"type"` field to determine the target module, validates against
  `event_type`, then reconstructs the typed struct.

  ## Versioned envelope
      decode!("RunStarted", %{"v" => 1, "data" => %TypedEvent{}})  → typed dispatch
      decode!("run_started", %{"v" => 0, "data" => %{"type" => "run_started", ...}}) → legacy dispatch
  For `v=1`: data is a typed struct and is validated against `event_type`.
  For `v=0`: data is a legacy map and is decoded using its own `"type"` field.

  This module is the read-side enforcement of TRD-001's authoritative vocabulary.
  Every event read from the EventStore must pass through here before being passed
  to an aggregate's `apply_event/2`.
  """

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @doc """
  Decode an event from any representation into a typed struct.

  `event_type` is the authoritative event type string (e.g. `"RunStarted"`,
  `"run_started"`) as stored in the EventStore record. `data` is the raw payload
  which may be a typed struct, a versioned envelope, a modern JSON map, or a
  legacy map.

  Raises:
  - `ArgumentError` if the typed struct's module does not match `event_type`
  - `ArgumentError` if the JSON/legacy map contains an unknown key
  - `ArgumentError` if the legacy map has no `"type"` field
  - `ArgumentError` if `event_type` is unknown
  """
  @spec decode!(String.t(), struct() | map()) :: struct()

  # Typed struct: validate module matches event_type
  def decode!(event_type, %_{} = data) do
    typed_validate!(event_type, data)
  end

  # Versioned envelope v=1: data is typed struct, validate against event_type
  def decode!(event_type, %{"v" => 1, "data" => data}) do
    decode!(event_type, data)
  end

  # Versioned envelope v=0: data is legacy map, compare against event_type
  def decode!(event_type, %{"v" => 0, "data" => data}) do
    decode_legacy!(event_type, data)
  end

  # Modern JSON map (has __struct__)
  def decode!(event_type, %{"__struct__" => _} = data) do
    typed_from_map!(event_type, data)
  end

  # Legacy map (no __struct__): compare against event_type
  def decode!(event_type, %{} = data) do
    decode_legacy!(event_type, data)
  end

  def decode!(_event_type, other) do
    raise ArgumentError,
      message:
        "EventCodec.decode!/2 expected a typed struct or a map, got: #{inspect(other)}"
  end

  # -------------------------------------------------------------------
  # Typed struct validation
  # -------------------------------------------------------------------

  # Validate the struct's module matches the expected event_type.
  # Raises if the module doesn't correspond to event_type (AC3).
  defp typed_validate!(event_type, %module{} = data) do
    expected_module = event_type_to_module!(normalize(event_type))

    if module == expected_module do
      data
    else
      raise ArgumentError,
        message:
          "EventCodec: struct module #{inspect(module)} does not match event_type #{
            inspect(event_type)
          }; expected #{inspect(expected_module)}"
    end
  end

  # -------------------------------------------------------------------
  # Map → typed struct (modern: has __struct__)
  # -------------------------------------------------------------------

  defp typed_from_map!(event_type, %{"__struct__" => struct_module} = map) do
    # Resolve expected module first; derive its canonical string form without "Elixir." prefix.
    # No dynamic Module.concat on arbitrary strings — no atom interning.
    expected_module = event_type_to_module!(normalize(event_type))
    expected_str = Atom.to_string(expected_module) |> String.trim_leading("Elixir.")

    unless struct_module == expected_str do
      raise ArgumentError,
        message:
          "EventCodec: map __struct__ #{inspect(struct_module)} does not match event_type #{
            inspect(event_type)
          }; expected #{inspect(expected_str)}"
    end

    # Strip __struct__ before field validation; use resolved expected_module
    stripped = Map.delete(map, "__struct__")
    validate_and_build!(stripped, expected_module)
  end

  # -------------------------------------------------------------------
  # Legacy map decoder (no __struct__, use "type" field)
  # -------------------------------------------------------------------

  defp decode_legacy!(expected_event_type, %{"type" => type} = map) when is_binary(type) do
    # Compare normalized expected type against normalized inner type
    expected_normalized = normalize(expected_event_type)
    inner_normalized = normalize(type)

    unless inner_normalized == expected_normalized do
      raise ArgumentError,
        message:
          "EventCodec: inner \"type\" field #{inspect(type)} does not match expected event_type #{
            inspect(expected_event_type)
          }"
    end

    module = event_type_to_module!(type)

    # Strip type before field validation
    stripped = Map.delete(map, "type")
    validate_and_build!(stripped, module)
  end

  defp decode_legacy!(_expected_event_type, map) do
    raise ArgumentError,
      message:
        "EventCodec.decode!/2 legacy map must have a \"type\" field; got keys: #{
          inspect(Map.keys(map))
        }"
  end

  # -------------------------------------------------------------------
  # Shared validation and struct construction
  # -------------------------------------------------------------------

  defp validate_and_build!(map, module) do
    # Validate string keys against known string field names — no atom interning.
    known_strings =
      MapSet.new(known_fields(module), &Atom.to_string/1)

    map
    |> Map.keys()
    |> Enum.each(fn key ->
      str_key = if is_atom(key), do: Atom.to_string(key), else: key

      unless MapSet.member?(known_strings, str_key) do
        raise KeyError,
          key: str_key,
          message:
            "EventCodec.decode!/2: unknown key #{inspect(str_key)} for event type #{
              inspect(module)
            }. Known fields: #{inspect(known_strings)}"
      end
    end)

    to_struct!(map, module)
  end

  # Build the typed struct from a map.
  # Only fields present in the map (by atom or string key) are included in args.
  # struct!/2 then enforces @enforce_keys and applies declared defaults for omitted optional fields.
  defp to_struct!(map, module) do
    args =
      Enum.flat_map(known_fields(module), fn field ->
        str_field = Atom.to_string(field)

        cond do
          is_map_key(map, field) -> [{field, Map.fetch!(map, field)}]
          is_map_key(map, str_field) -> [{field, Map.fetch!(map, str_field)}]
          true -> []
        end
      end)

    struct!(module, args)
  end
  # Normalize an event_type string to snake_case for lookup.
  # Handles both CamelCase ("RunStarted") and snake_case ("run_started").
  defp normalize(event_type) do
    Macro.underscore(event_type)
  end

  # -------------------------------------------------------------------
  # -------------------------------------------------------------------
  # Module ↔ event_type string mapping
  # -------------------------------------------------------------------

  # "run_started" → ForemanServer.Events.RunStarted
  defp event_type_to_module!("run_started"), do: ForemanServer.Events.RunStarted
  defp event_type_to_module!("phase_started"), do: ForemanServer.Events.PhaseStarted
  defp event_type_to_module!("phase_completed"), do: ForemanServer.Events.PhaseCompleted
  defp event_type_to_module!("phase_failed"), do: ForemanServer.Events.PhaseFailed
  defp event_type_to_module!("phase_timed_out"), do: ForemanServer.Events.PhaseTimedOut
  defp event_type_to_module!("phase_retried"), do: ForemanServer.Events.PhaseRetried
  defp event_type_to_module!("phase_skipped"), do: ForemanServer.Events.PhaseSkipped
  defp event_type_to_module!("phase_report_produced"), do: ForemanServer.Events.PhaseReportProduced
  defp event_type_to_module!("phase_verdict"), do: ForemanServer.Events.PhaseVerdict
  defp event_type_to_module!("project_registered"), do: ForemanServer.Events.ProjectRegistered
  defp event_type_to_module!("project_updated"), do: ForemanServer.Events.ProjectUpdated
  defp event_type_to_module!("project_archived"), do: ForemanServer.Events.ProjectArchived
  defp event_type_to_module!("project_reactivated"), do: ForemanServer.Events.ProjectReactivated
  defp event_type_to_module!("run_started"), do: ForemanServer.Events.RunStarted
  defp event_type_to_module!("run_updated"), do: ForemanServer.Events.RunUpdated
  defp event_type_to_module!("run_completed"), do: ForemanServer.Events.RunCompleted
  defp event_type_to_module!("run_failed"), do: ForemanServer.Events.RunFailed
  defp event_type_to_module!("run_blocked"), do: ForemanServer.Events.RunBlocked
  defp event_type_to_module!("run_deleted"), do: ForemanServer.Events.RunDeleted
  defp event_type_to_module!("task_created"), do: ForemanServer.Events.TaskCreated
  defp event_type_to_module!("task_updated"), do: ForemanServer.Events.TaskUpdated
  defp event_type_to_module!("task_annotated"), do: ForemanServer.Events.TaskAnnotated
  defp event_type_to_module!("task_dependency_added"), do: ForemanServer.Events.TaskDependencyAdded
  defp event_type_to_module!("worker_started"), do: ForemanServer.Events.WorkerStarted
  defp event_type_to_module!("worker_heartbeat"), do: ForemanServer.Events.WorkerHeartbeat
  defp event_type_to_module!("worker_exited"), do: ForemanServer.Events.WorkerExited
  defp event_type_to_module!("assistant_message"), do: ForemanServer.Events.AssistantMessage
  defp event_type_to_module!("worker_stdout"), do: ForemanServer.Events.WorkerStdout
  defp event_type_to_module!("worker_stderr"), do: ForemanServer.Events.WorkerStderr
  defp event_type_to_module!("tool_call_requested"), do: ForemanServer.Events.ToolCallRequested
  defp event_type_to_module!("tool_call_approved"), do: ForemanServer.Events.ToolCallApproved
  defp event_type_to_module!("tool_call_denied"), do: ForemanServer.Events.ToolCallDenied
  defp event_type_to_module!("tool_call_finished"), do: ForemanServer.Events.ToolCallFinished
  defp event_type_to_module!("scheduler_ticked"), do: ForemanServer.Events.SchedulerTicked
  defp event_type_to_module!("scheduler_task_claimed"), do: ForemanServer.Events.SchedulerTaskClaimed
  defp event_type_to_module!("scheduler_task_skipped"), do: ForemanServer.Events.SchedulerTaskSkipped
  defp event_type_to_module!("worktree_created"), do: ForemanServer.Events.WorktreeCreated
  defp event_type_to_module!("worktree_cleaned"), do: ForemanServer.Events.WorktreeCleaned
  defp event_type_to_module!("vcs_merge_requested"), do: ForemanServer.Events.VcsMergeRequested
  defp event_type_to_module!("pr_gate_observed"), do: ForemanServer.Events.PrGateObserved
  defp event_type_to_module!("vcs_pr_merged"), do: ForemanServer.Events.VcsPrMerged
  defp event_type_to_module!("merge_failed"), do: ForemanServer.Events.MergeFailed
  defp event_type_to_module!("merge_blocked"), do: ForemanServer.Events.MergeBlocked
  defp event_type_to_module!("attach_requested"), do: ForemanServer.Events.AttachRequested
  defp event_type_to_module!("attach_unsupported"), do: ForemanServer.Events.AttachUnsupported
  defp event_type_to_module!("external_trigger_command"), do: ForemanServer.Events.ExternalTriggerCommand
  defp event_type_to_module!("command_accepted"), do: ForemanServer.Events.CommandAccepted
  defp event_type_to_module!("external_worker_observed"), do: ForemanServer.Events.ExternalWorkerObserved
  defp event_type_to_module!("migration_import_started"), do: ForemanServer.Events.MigrationImportStarted
  defp event_type_to_module!("migration_record_imported"), do: ForemanServer.Events.MigrationRecordImported
  defp event_type_to_module!("migration_import_completed"), do: ForemanServer.Events.MigrationImportCompleted
  defp event_type_to_module!("inbox_message_appended"), do: ForemanServer.Events.InboxMessageAppended
  defp event_type_to_module!("inbox_delivery_updated"), do: ForemanServer.Events.InboxDeliveryUpdated
  defp event_type_to_module!("integration_command_ingested"), do: ForemanServer.Events.IntegrationCommandIngested
  defp event_type_to_module!("integration_configured"), do: ForemanServer.Events.IntegrationConfigured
  defp event_type_to_module!("integration_sync_requested"), do: ForemanServer.Events.IntegrationSyncRequested
  defp event_type_to_module!("integration_sync_completed"), do: ForemanServer.Events.IntegrationSyncCompleted
  defp event_type_to_module!("needs_operator"), do: ForemanServer.Events.NeedsOperator
  defp event_type_to_module!("human_interruption_recorded"), do: ForemanServer.Events.HumanInterruptionRecorded
  defp event_type_to_module!("interactive_recovery_resumed"), do: ForemanServer.Events.InteractiveRecoveryResumed
  defp event_type_to_module!("planning_flow_started"), do: ForemanServer.Events.PlanningFlowStarted
  defp event_type_to_module!("planning_flow_command"), do: ForemanServer.Events.PlanningFlowCommand
  defp event_type_to_module!("planning_trace_linked"), do: ForemanServer.Events.PlanningTraceLinked
  defp event_type_to_module!("planning_flow_completed"), do: ForemanServer.Events.PlanningFlowCompleted
  defp event_type_to_module!("worker_recovery_observed"), do: ForemanServer.Events.WorkerRecoveryObserved
  defp event_type_to_module!("worker_recovery_required"), do: ForemanServer.Events.WorkerRecoveryRequired
  defp event_type_to_module!("worker_reattached"), do: ForemanServer.Events.WorkerReattached
  defp event_type_to_module!("worker_restarted"), do: ForemanServer.Events.WorkerRestarted
  defp event_type_to_module!("recovery_resolved"), do: ForemanServer.Events.RecoveryResolved
  defp event_type_to_module!("pr_updated"), do: ForemanServer.Events.PrUpdated
  defp event_type_to_module!("pr_ready"), do: ForemanServer.Events.PrReady
  defp event_type_to_module!("pr_retargeted"), do: ForemanServer.Events.PrRetargeted
  defp event_type_to_module!("pr_reset"), do: ForemanServer.Events.PrReset
  defp event_type_to_module!("pr_merged"), do: ForemanServer.Events.PrMerged

  defp event_type_to_module!(other) do
    raise ArgumentError,
      message: "EventCodec.decode!/2: unknown event type string: #{inspect(other)}"
  end

  # -------------------------------------------------------------------
  # Known fields per event type (source: authoritative-events.md)
  # -------------------------------------------------------------------

  defp known_fields(ForemanServer.Events.RunStarted), do: [:run_id, :task_id]
  defp known_fields(ForemanServer.Events.RunUpdated), do: [:run_id, :task_id]
  defp known_fields(ForemanServer.Events.RunCompleted), do: [:run_id, :sequence]
  defp known_fields(ForemanServer.Events.RunFailed), do: [:run_id]
  defp known_fields(ForemanServer.Events.RunBlocked), do: [:run_id]
  defp known_fields(ForemanServer.Events.RunDeleted), do: [:run_id]
  defp known_fields(ForemanServer.Events.PhaseStarted), do: [:run_id, :phase_id]
  defp known_fields(ForemanServer.Events.PhaseCompleted), do: [:run_id, :phase_id]
  defp known_fields(ForemanServer.Events.PhaseFailed), do: [:run_id, :phase_id]
  defp known_fields(ForemanServer.Events.PhaseTimedOut), do: [:run_id, :phase_id]
  defp known_fields(ForemanServer.Events.PhaseRetried), do: [:run_id, :phase_id]
  defp known_fields(ForemanServer.Events.PhaseSkipped), do: [:run_id, :phase_id]
  defp known_fields(ForemanServer.Events.PhaseReportProduced), do: [:run_id, :phase_id, :report_id, :metadata]
  defp known_fields(ForemanServer.Events.PhaseVerdict), do: [:run_id, :phase_id, :verdict, :status, :final]
  defp known_fields(ForemanServer.Events.ProjectRegistered), do: [:project_id, :path, :status, :default_branch, :config, :health]
  defp known_fields(ForemanServer.Events.ProjectUpdated), do: [:project_id]
  defp known_fields(ForemanServer.Events.ProjectArchived), do: [:project_id]
  defp known_fields(ForemanServer.Events.ProjectReactivated), do: [:project_id]
  defp known_fields(ForemanServer.Events.TaskCreated), do: [:task_id, :project_id, :title, :description, :priority, :status, :dependencies, :task_type, :source, :external_id, :external_link, :dedupe_key, :integration_event_type, :planning_run_id, :planning_kind, :planning_phase_id, :trace_event_id]
  defp known_fields(ForemanServer.Events.TaskUpdated), do: [:task_id, :status]
  defp known_fields(ForemanServer.Events.TaskAnnotated), do: [:task_id, :body, :author, :created_at, :metadata]
  defp known_fields(ForemanServer.Events.TaskDependencyAdded), do: [:task_id, :depends_on]
  defp known_fields(ForemanServer.Events.WorkerStarted), do: [:worker_id, :run_id]
  defp known_fields(ForemanServer.Events.WorkerHeartbeat), do: [:worker_id, :run_id]
  defp known_fields(ForemanServer.Events.WorkerExited), do: [:worker_id, :run_id]
  defp known_fields(ForemanServer.Events.AssistantMessage), do: [:worker_id, :run_id]
  defp known_fields(ForemanServer.Events.WorkerStdout), do: [:worker_id, :run_id]
  defp known_fields(ForemanServer.Events.WorkerStderr), do: [:worker_id, :run_id]
  defp known_fields(ForemanServer.Events.ToolCallRequested), do: [:tool_call_id, :tool_name, :input, :run_id]
  defp known_fields(ForemanServer.Events.ToolCallApproved), do: [:tool_call_id]
  defp known_fields(ForemanServer.Events.ToolCallDenied), do: [:tool_call_id]
  defp known_fields(ForemanServer.Events.ToolCallFinished), do: [:tool_call_id, :worker_id, :run_id]
  defp known_fields(ForemanServer.Events.SchedulerTicked), do: [:project_id]
  defp known_fields(ForemanServer.Events.SchedulerTaskClaimed), do: [:project_id, :task_id]
  defp known_fields(ForemanServer.Events.SchedulerTaskSkipped), do: [:project_id, :task_id]
  defp known_fields(ForemanServer.Events.WorktreeCreated), do: [:worktree_id, :run_id]
  defp known_fields(ForemanServer.Events.WorktreeCleaned), do: [:worktree_id, :run_id]
  defp known_fields(ForemanServer.Events.VcsMergeRequested), do: [:operation_id, :run_id]
  defp known_fields(ForemanServer.Events.PrGateObserved), do: [:operation_id, :run_id, :gate, :state]
  defp known_fields(ForemanServer.Events.VcsPrMerged), do: [:operation_id, :run_id]
  defp known_fields(ForemanServer.Events.MergeFailed), do: [:operation_id, :run_id, :reason]
  defp known_fields(ForemanServer.Events.MergeBlocked), do: [:operation_id, :run_id, :reason]
  defp known_fields(ForemanServer.Events.AttachRequested), do: [:run_id, :worker_id]
  defp known_fields(ForemanServer.Events.AttachUnsupported), do: [:run_id, :worker_id]
  defp known_fields(ForemanServer.Events.ExternalTriggerCommand), do: [:trigger_id, :command]
  defp known_fields(ForemanServer.Events.CommandAccepted), do: [:trigger_id, :command]
  defp known_fields(ForemanServer.Events.ExternalWorkerObserved), do: [:trigger_id]
  defp known_fields(ForemanServer.Events.MigrationImportStarted), do: [:run_id, :task_id, :project_id]
  defp known_fields(ForemanServer.Events.MigrationRecordImported), do: [:run_id, :task_id, :record_id]
  defp known_fields(ForemanServer.Events.MigrationImportCompleted), do: [:run_id, :task_id, :count]
  defp known_fields(ForemanServer.Events.InboxMessageAppended), do: [:run_id, :message_id, :body, :metadata]
  defp known_fields(ForemanServer.Events.InboxDeliveryUpdated), do: [:run_id, :message_id, :delivery_status, :metadata]
  defp known_fields(ForemanServer.Events.IntegrationCommandIngested), do: [:integration_id, :command]
  defp known_fields(ForemanServer.Events.IntegrationConfigured), do: [:integration_id, :config]
  defp known_fields(ForemanServer.Events.IntegrationSyncRequested), do: [:integration_id]
  defp known_fields(ForemanServer.Events.IntegrationSyncCompleted), do: [:integration_id]
  defp known_fields(ForemanServer.Events.NeedsOperator), do: [:run_id]
  defp known_fields(ForemanServer.Events.HumanInterruptionRecorded), do: [:run_id]
  defp known_fields(ForemanServer.Events.InteractiveRecoveryResumed), do: [:run_id]
  defp known_fields(ForemanServer.Events.PlanningFlowStarted), do: [:run_id, :task_id, :kind]
  defp known_fields(ForemanServer.Events.PlanningFlowCommand), do: [:run_id, :task_id, :command]
  defp known_fields(ForemanServer.Events.PlanningTraceLinked), do: [:run_id, :task_id, :trace_id]
  defp known_fields(ForemanServer.Events.PlanningFlowCompleted), do: [:run_id, :task_id]
  defp known_fields(ForemanServer.Events.WorkerRecoveryObserved), do: [:run_id]
  defp known_fields(ForemanServer.Events.WorkerRecoveryRequired), do: [:run_id]
  defp known_fields(ForemanServer.Events.WorkerReattached), do: [:run_id]
  defp known_fields(ForemanServer.Events.WorkerRestarted), do: [:run_id]
  defp known_fields(ForemanServer.Events.RecoveryResolved), do: [:run_id]
  defp known_fields(ForemanServer.Events.PrUpdated), do: [:run_id, :project_id, :task_id, :pr_url, :branch_name, :head_sha, :base_branch, :phase]
  defp known_fields(ForemanServer.Events.PrReady), do: [:run_id, :project_id, :task_id, :pr_url, :branch_name, :head_sha, :base_branch]
  defp known_fields(ForemanServer.Events.PrRetargeted), do: [:run_id, :project_id, :task_id, :pr_url, :branch_name, :old_base_branch, :new_base_branch, :head_sha]
  defp known_fields(ForemanServer.Events.PrReset), do: [:run_id, :project_id, :task_id, :pr_url, :branch_name, :action, :reason]
  defp known_fields(ForemanServer.Events.PrMerged), do: [:run_id, :project_id, :task_id, :pr_url, :branch_name]

  defp known_fields(module) do
    raise ArgumentError,
      message:
        "EventCodec.decode!/2: no known-fields definition for module #{inspect(module)}"
  end
end
