defmodule ForemanServer.EventCodec do
  @moduledoc """
  Strict event reconstruction codec for typed events used by the Worker
  aggregate and the Overwatch Tracker.

  `decode!/2` is the sole entry point. It maps an `event_type` (String.t)
  to a registered struct module via `@registry` and rebuilds the struct
  from the persisted data map. There is **no permissive fallback**: any
  unregistered event_type raises `ArgumentError`.

  ## Decoding rules

    * A map whose `__struct__` matches the registered module is returned
      as-is (already-typed pass-through).
    * A map with a different `__struct__` raises `ArgumentError` (mismatch).
    * A plain map (no `__struct__`) is translated by iterating ONLY over
      the declared struct fields and looking each up by atom-or-string key
      in the input map. Missing enforced fields raise. Unknown input keys
      raise. Arbitrary input is never atomized.

  Scope: Worker aggregate + Overwatch lifecycle events. Other aggregates
  continue using `ForemanServer.Aggregate.event_type/1` /
  `event_payload/1` against persisted map data.
  """

  alias ForemanServer.Events.{
    AssistantMessage,
    BeadsDbLeaseAcquired,
    BeadsDbLeaseReleased,
    BeadsDbLeaseTransferred,
    BeadsDbLeaseWaiterRegistered,
    BeadsDbLeaseWaiterRemoved,
    PhaseCompleted,
    PhaseFailed,
    PhaseStarted,
    ProjectRunReservationReleased,
    ProjectRunReserved,
    RunBlocked,
    RunCancelled,
    RunCompleted,
    RunFailed,
    RunFlaggedStuck,
    RunPaused,
    RunSlotAcquired,
    RunSlotQueued,
    RunSlotReleased,
    RunSlotTransferred,
    RunSlotWaiterRemoved,
    RunStarted,
    ProjectRunReservationReleased,
    ProjectRunReserved,
    RunBlocked,
    RunCancelled,
    RunCompleted,
    RunFailed,
    RunFlaggedStuck,
    RunPaused,
    RunStarted,
    TaskAnnotated,
    TaskApproved,
    TaskCreated,
    TaskDependencyAdded,
    TaskDispatched,
    TaskExecutionCompleted,
    TaskExecutionFailed,
    TaskRetried,
    TaskRunTerminated,
    TaskUpdated,
    ToolCallFinished,
    WorkerCrashed,
    WorkerExited,
    WorkerHeartbeat,
    WorkerStarted,
    WorkerStderr,
    WorkerStdout,
    WorkerUnresponsive,
    WorktreeCreated,
    WorktreeCleaned,
    WorktreeCreateOrphanRecorded,
    WorktreeCreateOrphanResolved,
    WorkSubmitted,
    WorkCancelled,
    WorkExecutionCompleted,
    WorkExecutionFailed
  }

  @registry %{
    "BeadsDbLeaseAcquired" => BeadsDbLeaseAcquired,
    "BeadsDbLeaseReleased" => BeadsDbLeaseReleased,
    "BeadsDbLeaseWaiterRegistered" => BeadsDbLeaseWaiterRegistered,
    "BeadsDbLeaseWaiterRemoved" => BeadsDbLeaseWaiterRemoved,
    "BeadsDbLeaseTransferred" => BeadsDbLeaseTransferred,
    "WorkerStarted" => WorkerStarted,
    "WorkerHeartbeat" => WorkerHeartbeat,
    "WorkerUnresponsive" => WorkerUnresponsive,
    "WorkerExited" => WorkerExited,
    "WorkerCrashed" => WorkerCrashed,
    "WorkerStdout" => WorkerStdout,
    "WorkerStderr" => WorkerStderr,
    "ToolCallFinished" => ToolCallFinished,
    "AssistantMessage" => AssistantMessage,
    "RunStarted" => RunStarted,
    "ProjectRunReserved" => ProjectRunReserved,
    "ProjectRunReservationReleased" => ProjectRunReservationReleased,
    "RunCompleted" => RunCompleted,
    "RunFailed" => RunFailed,
    "RunBlocked" => RunBlocked,
    "RunFlaggedStuck" => RunFlaggedStuck,
    "RunPaused" => RunPaused,
    "RunCancelled" => RunCancelled,
    "RunSlotAcquired" => RunSlotAcquired,
    "RunSlotQueued" => RunSlotQueued,
    "RunSlotReleased" => RunSlotReleased,
    "RunSlotTransferred" => RunSlotTransferred,
    "RunSlotWaiterRemoved" => RunSlotWaiterRemoved,
    "PhaseStarted" => PhaseStarted,
    "PhaseCompleted" => PhaseCompleted,
    "PhaseFailed" => PhaseFailed,
    "TaskCreated" => TaskCreated,
    "TaskUpdated" => TaskUpdated,
    "TaskAnnotated" => TaskAnnotated,
    "TaskDependencyAdded" => TaskDependencyAdded,
    "TaskApproved" => TaskApproved,
    "TaskDispatched" => TaskDispatched,
    "TaskExecutionCompleted" => TaskExecutionCompleted,
    "TaskExecutionFailed" => TaskExecutionFailed,
    "TaskRunTerminated" => TaskRunTerminated,
    "TaskRetried" => TaskRetried,
    "WorkSubmitted" => WorkSubmitted,
    "WorkCancelled" => WorkCancelled,
    "WorkExecutionCompleted" => WorkExecutionCompleted,
    "WorkExecutionFailed" => WorkExecutionFailed,
    "WorktreeCreated" => WorktreeCreated,
    "WorktreeCleaned" => WorktreeCleaned,
    "WorktreeCreateOrphanRecorded" => WorktreeCreateOrphanRecorded,
    "WorktreeCreateOrphanResolved" => WorktreeCreateOrphanResolved
  }

  # Parallel registry of @enforce_keys per event module. `Module.get_attribute/2`
  # is compile-time only, so the enforced fields are registered here for
  # runtime validation. Update both `@registry` and `@enforce_keys_registry`
  @enforce_keys_registry %{
    BeadsDbLeaseAcquired => [:db_path, :run_id, :task_id, :acquired_at_ms],
    BeadsDbLeaseReleased => [:db_path, :run_id, :released_at_ms, :reason],
    BeadsDbLeaseTransferred => [
      :db_path,
      :released_run_id,
      :released_at_ms,
      :reason,
      :acquired_run_id,
      :acquired_task_id,
      :acquired_at_ms,
      :enqueued_at_ms
    ],
    BeadsDbLeaseWaiterRegistered => [:db_path, :run_id, :task_id, :enqueued_at_ms],
    BeadsDbLeaseWaiterRemoved => [:db_path, :run_id, :removed_at_ms, :reason],
    WorkerStarted => [:worker_id, :run_id, :session_id, :adapter, :prompt_path],
    WorkerHeartbeat => [:worker_id, :run_id],
    WorkerUnresponsive => [:worker_id, :run_id],
    WorkerExited => [:worker_id],
    WorkerCrashed => [:worker_id, :run_id],
    WorkerStdout => [:worker_id, :run_id],
    WorkerStderr => [:worker_id, :run_id],
    ToolCallFinished => [:worker_id, :run_id],
    AssistantMessage => [:worker_id, :run_id],
    RunStarted => [:run_id, :task_id, :project_id, :workflow_snapshot],
    ProjectRunReserved => [:project_id, :run_id, :sequence, :command_id, :run_start_payload],
    ProjectRunReservationReleased => [:project_id, :run_id, :sequence],
    RunCompleted => [:run_id, :project_id, :sequence],
    RunFailed => [:run_id, :project_id, :sequence],
    RunBlocked => [:run_id, :project_id],
    RunFlaggedStuck => [:run_id, :project_id, :flagged_at],
    RunCancelled => [:run_id, :project_id],
    RunPaused => [:run_id],
    PhaseStarted => [:phase_id, :run_id, :index, :name, :attempt, :artifact_template],
    PhaseCompleted => [
      :phase_id,
      :run_id,
      :index,
      :artifact_path,
      :artifact_sha256,
      :artifact_bytes
    ],
    PhaseFailed => [:run_id, :phase_id, :index, :reason],
    TaskCreated => [:task_id, :project_id, :title, :status, :task_type],
    TaskUpdated => [:task_id],
    TaskAnnotated => [:task_id, :body, :author],
    TaskDependencyAdded => [:task_id, :depends_on],
    TaskApproved => [
      :task_id,
      :approval_id,
      :approved_by,
      :approved_at,
      :run_id,
      :workflow_snapshot
    ],
    TaskDispatched => [:task_id, :run_id, :approval_id],
    TaskExecutionCompleted => [:task_id, :run_id],
    TaskExecutionFailed => [:task_id, :run_id, :reason],
    TaskRunTerminated => [:task_id, :run_id],
    TaskRetried => [:task_id, :previous_run_id],
    WorktreeCreated => [:operation_id, :project_id, :run_id, :phase_id],
    WorktreeCleaned => [:operation_id, :project_id, :run_id, :phase_id],
    WorktreeCreateOrphanRecorded => [
      :operation_id,
      :project_id,
      :run_id,
      :phase_id,
      :worktree_path
    ],
    WorktreeCreateOrphanResolved => [:operation_id, :project_id, :run_id, :phase_id],
    WorkSubmitted => [:work_id, :project_id, :run_id, :submission_id, :workflow_snapshot],
    WorkCancelled => [:work_id],
    WorkExecutionCompleted => [:work_id, :run_id],
    WorkExecutionFailed => [:work_id, :run_id],
    RunSlotAcquired => [:run_id, :capacity, :acquired_at_ms],
    RunSlotQueued => [:run_id, :position, :enqueued_at_ms],
    RunSlotReleased => [:run_id],
    RunSlotTransferred => [:released_run_id, :acquired_run_id, :acquired_at_ms],
    RunSlotWaiterRemoved => [:run_id]
  }

  @type event_type :: String.t()
  @type data :: map()
  @type typed_event :: struct()

  @doc """
  Strictly decode a persisted event into its typed struct.

  Raises `ArgumentError` if `event_type` is not registered, the data
  carries a mismatched struct, an enforced key is missing, or an input
  key does not correspond to a declared struct field.
  """
  @spec decode!(event_type(), data()) :: typed_event()
  def decode!(event_type, data) when is_binary(event_type) and is_map(data) do
    module = registered_module!(event_type)

    case data do
      %{__struct__: ^module} = struct ->
        struct

      %{__struct__: other_module} ->
        raise ArgumentError,
              "EventCodec mismatch: event_type=#{inspect(event_type)} expects " <>
                "#{inspect(module)}, got #{inspect(other_module)}"

      plain_map when is_map(plain_map) ->
        build_struct(module, plain_map, event_type)
    end
  end

  def decode!(event_type, data) do
    raise ArgumentError,
          "ForemanServer.EventCodec.decode!/2 expects (binary, map); got " <>
            "(#{inspect(event_type)}, #{inspect(data)})"
  end

  @doc "Decode from a `%RecordedEvent{}` (replay path)."
  @spec decode_recorded!(struct()) :: typed_event()
  def decode_recorded!(%{event_type: type, data: data}), do: decode!(type, data)

  @doc "Registered event types. Diagnostic only."
  @spec registered() :: [event_type()]
  def registered, do: Map.keys(@registry)

  # ------------------------------------------------------------------
  # Internal
  # ------------------------------------------------------------------

  defp registered_module!(event_type) do
    case Map.fetch(@registry, event_type) do
      {:ok, module} ->
        module

      :error ->
        raise ArgumentError,
              "ForemanServer.EventCodec: unregistered event_type #{inspect(event_type)}. " <>
                "Register it in @registry and add the typed struct under ForemanServer.Events."
    end
  end

  defp build_struct(module, plain_map, event_type) do
    struct_keys = struct_field_names(module)
    enforce_keys = Map.fetch!(@enforce_keys_registry, module)
    declared_atom_keys = struct_keys
    declared_string_keys = Enum.map(struct_keys, &Atom.to_string/1)

    reject_duplicate_forms!(plain_map, declared_string_keys, event_type)
    reject_unknown_keys!(plain_map, declared_atom_keys, declared_string_keys, event_type)

    # Build pairs ONLY for fields actually present in the input. Absent
    # fields keep their declared default via `struct!/2`.
    pairs =
      plain_map
      |> Enum.flat_map(fn
        {:__struct__, _} ->
          []

        {k, v} when is_atom(k) ->
          if Enum.member?(declared_atom_keys, k), do: [{k, v}], else: []

        {k, v} when is_binary(k) ->
          if Enum.member?(declared_string_keys, k) do
            # Safe: we verified k is one of our declared string keys, so
            # the corresponding atom is guaranteed to exist.
            [{String.to_existing_atom(k), v}]
          else
            []
          end

        _ ->
          []
      end)

    missing_enforced = enforce_keys -- Keyword.keys(pairs)

    case missing_enforced do
      [] ->
        :ok

      keys ->
        raise ArgumentError,
              "EventCodec: event_type=#{inspect(event_type)} missing enforced keys: " <>
                "#{inspect(keys)}"
    end

    struct!(module, pairs)
  end

  defp reject_duplicate_forms!(plain_map, declared_string_keys, event_type) do
    duplicates =
      plain_map
      |> Map.keys()
      |> Enum.flat_map(fn
        k when is_atom(k) ->
          string_form = Atom.to_string(k)

          if string_form in declared_string_keys and Map.has_key?(plain_map, string_form) do
            [k]
          else
            []
          end

        _ ->
          []
      end)

    case duplicates do
      [] ->
        :ok

      keys ->
        raise ArgumentError,
              "EventCodec: event_type=#{inspect(event_type)} contains both atom and " <>
                "string forms of: #{inspect(keys)}"
    end
  end

  defp reject_unknown_keys!(plain_map, declared_atom_keys, declared_string_keys, event_type) do
    unknown_keys =
      plain_map
      |> Map.keys()
      |> Enum.reject(fn
        :__struct__ -> true
        k when is_atom(k) -> k in declared_atom_keys
        k when is_binary(k) -> k in declared_string_keys
        _ -> false
      end)

    case unknown_keys do
      [] ->
        :ok

      keys ->
        raise ArgumentError,
              "EventCodec: event_type=#{inspect(event_type)} has unknown fields: " <>
                "#{inspect(keys)}; declared: #{inspect(declared_atom_keys)}"
    end
  end

  defp struct_field_names(module) do
    module.__struct__()
    |> Map.from_struct()
    |> Map.keys()
  end
end
