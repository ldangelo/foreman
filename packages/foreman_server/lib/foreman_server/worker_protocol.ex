defmodule ForemanServer.WorkerProtocol do
  @moduledoc "HTTP-facing Node/Pi worker protocol: phase start, events, and heartbeat."

  alias ForemanServer.{
    Aggregate,
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
           }) do
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
      })
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

      details = Map.get(payload, :details, %{})

      append_worker_event(event_type, %{
        run_id: run_id,
        project_id: Map.get(payload, :project_id) || Map.get(details, "project_id"),
        task_id:
          Map.get(payload, :task_id) || Map.get(details, "task_id") || Map.get(details, "taskId"),
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

  defp redact_env(env) when is_map(env) do
    Map.new(env, fn {key, _value} -> {key, "[REDACTED]"} end)
  end

  defp append_worker_event(event_type, payload) do
    stream_id = "worker:#{payload.run_id}:#{payload.worker_id}"
    idempotency_key = "#{event_type}:#{payload.run_id}:#{payload.worker_id}:#{payload.sequence}"

    case validate_sequence(stream_id, payload.sequence, idempotency_key) do
      {:ok, expected_version} ->
        with :ok <- reject_event_after_terminal_run(event_type, payload.run_id),
             {:ok, event} <-
               EventStore.append(%{
                 stream_id: stream_id,
                 event_type: event_type,
                 payload: Map.put(payload, :observed_at, DateTime.utc_now()),
                 expected_stream_version: expected_version,
                 metadata: %{
                   correlation_id: payload.run_id,
                   idempotency_key: idempotency_key
                 }
               }) do
          {:ok, %{event: event, projection: ProjectionStore.snapshot()}}
        end

      {:duplicate, event} ->
        {:ok, %{event: event, projection: ProjectionStore.snapshot()}}

      {:error, reason} ->
        {:error, reason}
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
      :message,
      :model,
      :output,
      :phase_id,
      :pid,
      :project_id,
      :project_secrets,
      :prompt_path,
      :provider,
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
