defmodule ForemanServer.WorkerProtocol do
  @moduledoc "HTTP-facing Node/Pi worker protocol: phase start, events, and heartbeat."

  alias ForemanServer.{
    Aggregate,
    CommandRouter,
    EventStore,
    ProjectionStore,
    ProviderRegistry,
    WorkerEnvironment
  }

  alias ForemanServer.Aggregates.Worker

  @terminal_run_statuses MapSet.new(["completed", "failed", "blocked"])
  @after_terminal_run_events MapSet.new(["RunCompleted", "RunFailed", "TaskUpdated"])

  @spec start_phase(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def start_phase(phase_id, payload) when is_binary(phase_id) and is_map(payload) do
    payload = atomize_keys(payload)
    run_id = Map.get(payload, :run_id)
    worker_id = Map.get(payload, :worker_id, "worker-#{phase_id}")

    with {:ok, run_id} <- required_binary(run_id, :run_id),
         {:ok, worker_id} <- required_binary(worker_id, :worker_id),
         {:ok, adapter} <-
           ProviderRegistry.resolve(%{
             provider: Map.get(payload, :adapter, Map.get(payload, :provider, "pi_sdk")),
             model: Map.get(payload, :model),
             tool_names: Map.get(payload, :tool_names, [])
           }),
         {:ok, prepared_env} <-
           WorkerEnvironment.prepare(%{
             project_id: Map.get(payload, :project_id, "default"),
             run_id: run_id,
             env: Map.get(payload, :env, %{}),
             project_secrets: Map.get(payload, :project_secrets, %{}),
             run_secrets: Map.get(payload, :run_secrets, %{})
           }),
         {:ok, _} <- ensure_phase_started(run_id, phase_id),
         {:ok, worker_result} <-
           append_worker_event("WorkerStarted", %{
             run_id: run_id,
             project_id: Map.get(payload, :project_id, "default"),
             phase_id: phase_id,
             worker_id: worker_id,
             adapter: adapter.id,
             session_id: Map.get(payload, :session_id),
             prompt_path: Map.get(payload, :prompt_path),
             tool_names: Map.get(payload, :tool_names, []),
             artifact_paths: Map.get(payload, :artifact_paths, []),
             prepared_env: redact_env(prepared_env.env),
             prepared_env_keys: prepared_env.env |> Map.keys() |> Enum.sort(),
             stripped_env_keys: prepared_env.stripped,
             scoped_secret_keys: prepared_env.scoped_secret_keys,
             sequence: 0
           }) do
      {:ok, worker_result}
    end
  end


  # Ensure the Phase aggregate stream exists by dispatching phase.start.
  # Only unexpected errors propagate; :phase_already_started and
  # :duplicate_idempotency_key are swallowed here.
  defp ensure_phase_started(run_id, phase_id) do
    command_id = "phase-start:#{run_id}:#{phase_id}"

    case CommandRouter.handle(%{
           command_id: command_id,
           command_type: "phase.start",
           payload: %{run_id: run_id, phase_id: phase_id}
         }) do
      {:ok, _} -> {:ok, :phase_started}
      {:error, :phase_already_started} -> {:ok, :phase_already_started}
      {:error, {:phase_already_started, _}} -> {:ok, :phase_already_started}
      {:error, {:duplicate_idempotency_key, _}} -> {:ok, :duplicate}
      other -> other
    end
  end

  @spec heartbeat(map()) :: {:ok, map()} | {:error, term()}
  def heartbeat(payload) when is_map(payload) do
    payload = atomize_keys(payload)

    with {:ok, run_id} <- required_binary(Map.get(payload, :run_id), :run_id),
         {:ok, phase_id} <- required_binary(Map.get(payload, :phase_id), :phase_id),
         {:ok, worker_id} <- required_binary(Map.get(payload, :worker_id), :worker_id) do
      append_worker_event("WorkerHeartbeat", %{
        run_id: run_id,
        phase_id: phase_id,
        worker_id: worker_id,
        session_id: Map.get(payload, :session_id),
        attach: Map.get(payload, :attach, %{}),
        pid: Map.get(payload, :pid),
        sequence: Map.get(payload, :sequence, next_sequence(run_id, worker_id))
      })
    end
  end

  @spec ingest_event(map()) :: {:ok, map()} | {:error, term()}
  def ingest_event(payload) when is_map(payload) do
    payload = atomize_keys(payload)

    with {:ok, run_id} <- required_binary(Map.get(payload, :run_id), :run_id),
         {:ok, phase_id} <- required_binary(Map.get(payload, :phase_id), :phase_id),
         {:ok, worker_id} <- required_binary(Map.get(payload, :worker_id), :worker_id),
         {:ok, type} <- required_binary(Map.get(payload, :type), :type),
         {:ok, sequence} <- required_integer(Map.get(payload, :sequence), :sequence) do
      event_type = worker_event_type(type)

      # Phase/Run/Task events route to their own aggregates via CommandRouter.
      # Worker events (including ToolCallFinished which crosses domains) persist
      # to the worker stream via append_worker_event.
      if route_to_aggregate?(event_type) do
        route_to_aggregate(event_type, run_id, phase_id, worker_id, sequence, payload)
      else
        details = Map.get(payload, :details, %{})

        append_worker_event(event_type, %{
          run_id: run_id,
          project_id: Map.get(payload, :project_id) || Map.get(details, "project_id"),
          task_id:
            Map.get(payload, :task_id) || Map.get(details, "task_id") ||
            Map.get(details, "taskId"),
          phase_id: phase_id,
          worker_id: worker_id,
          sequence: sequence,
          tool_call_id: Map.get(payload, :tool_call_id),
          tool_name: Map.get(payload, :tool_name),
          status: Map.get(payload, :status) || Map.get(details, "status"),
          output: Map.get(payload, :output),
          message: Map.get(payload, :message),
          artifact_paths: Map.get(payload, :artifact_paths, []),
          report_paths: Map.get(payload, :report_paths, []),
          exit_code: Map.get(payload, :exit_code),
          details: details
        })
      end
    end
  end

  defp redact_env(env) when is_map(env) do
    Map.new(env, fn {key, _value} -> {key, "[REDACTED]"} end)
  end

  @doc """
  Public emit path for internal Overwatch components (Tracker, LaunchWorker).

  Accepts either a binary event_type + map payload (legacy path, payload is
  stringified and wrapped in the envelope by append_worker_event) OR a typed
  struct as payload — the struct is passed directly through the pipeline and
  serialized by EventStore.stringify_keys/1 before being written to the stream.

  For `WorkerStarted` the caller **must** supply `sequence: 0`.
  For all other events nil-sequence is auto-filled via `next_sequence/1` before
  sequence validation so the aggregate's idempotency guard is respected.

  Returns `{:ok, result}` on success, `{:error, reason}` on failure,
  or `{:ok, %{event: _, projection: _}}` on duplicate.
  """
  @spec emit(String.t(), map() | struct()) :: {:ok, map()} | {:error, term()}

  def emit(event_type, %_{} = payload) do
    # Typed struct path: normalize nil-sequence before persisting so the
    # aggregate's idempotency guard is respected.
    payload =
      case Map.get(payload, :sequence) do
        nil when event_type == "WorkerStarted" ->
          Map.put(payload, :sequence, 0)

        nil ->
          Map.put(payload, :sequence, next_sequence_for(payload))

        _ ->
          payload
      end

    append_worker_event(event_type, payload)
  end

  # Map-based legacy path for callers that still pass plain maps.
  def emit("WorkerStarted", payload) when is_map(payload) do
    append_worker_event("WorkerStarted", Map.put(payload, :sequence, 0))
  end

  def emit(event_type, payload) when is_map(payload) do
    payload =
      case Map.get(payload, :sequence) do
        nil -> Map.put(payload, :sequence, next_sequence_for(payload))
        _ -> payload
      end

    append_worker_event(event_type, payload)
  end

  defp next_sequence_for(payload) do
    stream_id = "worker:#{payload.run_id}:#{payload.worker_id}"
    {state, _version} = Aggregate.load(Worker, stream_id)
    Worker.next_sequence(state)
  end
  # Private helper called by public emit/2 and internal functions.
  defp append_worker_event(event_type, payload) do
    stream_id = "worker:#{payload.run_id}:#{payload.worker_id}"
    idempotency_key = "#{event_type}:#{payload.run_id}:#{payload.worker_id}:#{payload.sequence}"

    # 1. Duplicate check: already-recorded events return idempotent OK
    #    regardless of current terminal state.
    # 2. Terminal state check: new events after run went terminal are rejected.
    # 3. Sequence validation: only for genuinely new events.
    case duplicate_worker_event(stream_id, idempotency_key) do
      nil ->
        with :ok <- reject_event_after_terminal_run(event_type, payload.run_id),
             {:ok, _expected_version} <- validate_sequence(stream_id, payload.sequence, idempotency_key) do
          enriched_payload = Map.put(payload, :observed_at, DateTime.utc_now())

          CommandRouter.handle(%{
            command_id: idempotency_key,
            command_type: "worker.record",
            payload: Map.put(enriched_payload, :event_type, event_type)
          })
          |> case do
            {:ok, result} -> {:ok, result}
            {:error, reason} -> {:error, reason}
          end
        end

      event ->
        {:ok, %{event: event, projection: ProjectionStore.snapshot()}}
    end
  end

  defp reject_event_after_terminal_run(event_type, run_id) do
    run = get_in(ProjectionStore.snapshot(), [:runs, run_id])

    cond do
      MapSet.member?(@after_terminal_run_events, event_type) ->
        :ok

      is_map(run) and MapSet.member?(@terminal_run_statuses, Map.get(run, :status)) ->
        {:error, {:run_not_active, run_id}}

      true ->
        :ok
    end
  end

  defp validate_sequence(stream_id, sequence, idempotency_key) do
    {state, version} = Aggregate.load(Worker, stream_id)
    expected = Worker.next_sequence(state)

    cond do
      sequence == expected ->
        {:ok, version}

      duplicate = duplicate_worker_event(stream_id, idempotency_key) ->
        {:duplicate, duplicate}

      true ->
        {:error, {:out_of_order_sequence, expected: expected, actual: sequence}}
    end
  end

  defp duplicate_worker_event(stream_id, idempotency_key) do
    Enum.find(EventStore.stream(stream_id), fn event ->
      Map.get(event.metadata, :idempotency_key) == idempotency_key
    end)
  end

  defp next_sequence(run_id, worker_id) do
    {state, _version} = Aggregate.load(Worker, "worker:#{run_id}:#{worker_id}")
    Worker.next_sequence(state)
  end
  defp worker_event_type("stdout"), do: "WorkerStdout"
  defp worker_event_type("stderr"), do: "WorkerStderr"
  defp worker_event_type("assistant"), do: "AssistantMessage"
  defp worker_event_type("assistant_message"), do: "AssistantMessage"
  defp worker_event_type("tool_call_finished"), do: "ToolCallFinished"
  defp worker_event_type("heartbeat"), do: "WorkerHeartbeat"
  defp worker_event_type("worker_heartbeat"), do: "WorkerHeartbeat"
  defp worker_event_type("phase_completed"), do: "PhaseCompleted"
  defp worker_event_type("phase_failed"), do: "PhaseFailed"
  defp worker_event_type("phase_retry"), do: "PhaseRetried"
  defp worker_event_type("phase_skipped"), do: "PhaseSkipped"
  defp worker_event_type("phase_verdict"), do: "PhaseVerdict"
  defp worker_event_type("phase_nudge"), do: "PhaseNudged"
  defp worker_event_type("run_completed"), do: "RunCompleted"
  defp worker_event_type("run_failed"), do: "RunFailed"
  defp worker_event_type("task_updated"), do: "TaskUpdated"
  defp worker_event_type(type), do: Macro.camelize(type)

  @phase_run_task_events MapSet.new([
    "PhaseCompleted", "PhaseFailed", "PhaseRetried", "PhaseSkipped",
    "PhaseVerdict", "PhaseNudged",
    "RunCompleted", "RunFailed",
    "TaskUpdated"
  ])

  # Phase/Run/Task events are routed to their own aggregates so the aggregate
  # can enforce invariants and emit authoritative events into its own stream.
  defp route_to_aggregate?(event_type) do
    MapSet.member?(@phase_run_task_events, event_type)
  end

  defp route_to_aggregate(event_type, run_id, phase_id, worker_id, sequence, payload) do
    details = Map.get(payload, :details, %{})
    task_id = Map.get(payload, :task_id) || Map.get(details, "task_id") || Map.get(details, "taskId")

    {command_type, aggregate_payload} =
      case event_type do
        "PhaseCompleted" ->
          {"phase.complete",
           %{
             run_id: run_id,
             phase_id: phase_id,
             worker_id: worker_id,
             sequence: sequence,
             status: Map.get(payload, :status) || Map.get(details, "status"),
             output: Map.get(payload, :output),
             artifact_paths: Map.get(payload, :artifact_paths, []),
             report_paths: Map.get(payload, :report_paths, []),
             exit_code: Map.get(payload, :exit_code),
             message: Map.get(payload, :message)
           }}

        "PhaseFailed" ->
          {"phase.fail",
           %{
             run_id: run_id,
             phase_id: phase_id,
             worker_id: worker_id,
             sequence: sequence,
             status: Map.get(payload, :status) || Map.get(details, "status"),
             output: Map.get(payload, :output),
             artifact_paths: Map.get(payload, :artifact_paths, []),
             report_paths: Map.get(payload, :report_paths, []),
             exit_code: Map.get(payload, :exit_code),
             message: Map.get(payload, :message)
           }}

        "PhaseRetried" ->
          {"phase.retry",
           %{
             run_id: run_id,
             phase_id: phase_id,
             worker_id: worker_id,
             sequence: sequence,
             attempt: Map.get(details, "attempt")
           }}

        "PhaseSkipped" ->
          {"phase.skip",
           %{
             run_id: run_id,
             phase_id: phase_id,
             worker_id: worker_id,
             sequence: sequence,
             status: Map.get(payload, :status) || Map.get(details, "status")
           }}

        "PhaseVerdict" ->
          {"phase.verdict",
           %{
             run_id: run_id,
             phase_id: phase_id,
             worker_id: worker_id,
             sequence: sequence,
             status: Map.get(payload, :status) || Map.get(details, "status")
           }}

        "PhaseNudged" ->
          {"phase.nudge",
           %{run_id: run_id, phase_id: phase_id, worker_id: worker_id, sequence: sequence}}

        "RunCompleted" ->
          {"run.complete",
           %{
             run_id: run_id,
             phase_id: phase_id,
             worker_id: worker_id,
             sequence: sequence,
             task_id: task_id,
             status: Map.get(payload, :status) || Map.get(details, "status"),
             failure_reason: Map.get(details, "failure_reason") || Map.get(payload, :failure_reason),
             reason:
               Map.get(details, "reason") || Map.get(payload, :reason) ||
                 Map.get(details, "failure_reason") || Map.get(payload, :failure_reason),
             output: Map.get(payload, :output),
             artifact_paths: Map.get(payload, :artifact_paths, []),
             exit_code: Map.get(payload, :exit_code)
           }}

        "RunFailed" ->
          {"run.fail",
           %{
             run_id: run_id,
             phase_id: phase_id,
             worker_id: worker_id,
             sequence: sequence,
             task_id: task_id,
             status: Map.get(payload, :status) || Map.get(details, "status"),
             failure_reason: Map.get(details, "failure_reason") || Map.get(payload, :failure_reason),
             reason:
               Map.get(details, "reason") || Map.get(payload, :reason) ||
                 Map.get(details, "failure_reason") || Map.get(payload, :failure_reason) ||
                 Map.get(payload, :message),
             output: Map.get(payload, :output),
             artifact_paths: Map.get(payload, :artifact_paths, []),
             exit_code: Map.get(payload, :exit_code)
           }}
        "TaskUpdated" ->
          {"task.update",
           %{
             run_id: run_id,
             task_id: task_id,
             worker_id: worker_id,
             sequence: sequence,
             status: Map.get(payload, :status) || Map.get(details, "status"),
             output: Map.get(payload, :output)
           }}
      end

    command_id = "ingest:#{event_type}:#{run_id}:#{phase_id}:#{worker_id}:#{sequence}"

    case CommandRouter.handle(%{
           command_id: command_id,
           command_type: command_type,
           payload: aggregate_payload
         }) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp required_binary(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  defp required_binary(_value, key), do: {:error, {:missing_or_invalid, key}}

  defp required_integer(value, _key) when is_integer(value), do: {:ok, value}
  defp required_integer(_value, key), do: {:error, {:missing_or_invalid, key}}

  defp atomize_keys(map) when is_map(map) do
    Enum.reduce(known_keys(), %{}, fn key, acc ->
      case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
        nil -> acc
        value -> Map.put(acc, key, normalize_value(value))
      end
    end)
  end

  defp atomize_keys(_), do: %{}

  defp normalize_value(value) when is_map(value), do: stringify_nested_keys(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp stringify_nested_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp known_keys do
    [
      :adapter,
      :artifact_paths,
      :attach,
      :details,
      :env,
      :exit_code,
      :failure_reason,
      :message,
      :model,
      :output,
      :phase_id,
      :pid,
      :project_id,
      :project_secrets,
      :prompt_path,
      :provider,
      :reason,
      :report_paths,
      :run_id,
      :run_secrets,
      :sequence,
      :session_id,
      :status,
      :task_id,
      :tool_call_id,
      :tool_name,
      :tool_names,
      :type,
      :worker_id
    ]
  end
end
