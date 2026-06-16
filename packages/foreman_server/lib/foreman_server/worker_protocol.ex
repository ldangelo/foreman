defmodule ForemanServer.WorkerProtocol do
  @moduledoc "HTTP-facing Node/Pi worker protocol: phase start, events, and heartbeat."

  alias ForemanServer.{EventStore, ProjectionStore}

  @spec start_phase(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def start_phase(phase_id, payload) when is_binary(phase_id) and is_map(payload) do
    payload = atomize_keys(payload)
    run_id = Map.get(payload, :run_id)
    worker_id = Map.get(payload, :worker_id, "worker-#{phase_id}")

    with {:ok, run_id} <- required_binary(run_id, :run_id),
         {:ok, worker_id} <- required_binary(worker_id, :worker_id) do
      append_worker_event("WorkerStarted", %{
        run_id: run_id,
        phase_id: phase_id,
        worker_id: worker_id,
        adapter: Map.get(payload, :adapter, "pi_sdk"),
        session_id: Map.get(payload, :session_id),
        prompt_path: Map.get(payload, :prompt_path),
        tool_names: Map.get(payload, :tool_names, []),
        artifact_paths: Map.get(payload, :artifact_paths, []),
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
         {:ok, sequence} <- required_integer(Map.get(payload, :sequence), :sequence),
         :ok <- validate_sequence(run_id, worker_id, sequence) do
      event_type = worker_event_type(type)

      append_worker_event(event_type, %{
        run_id: run_id,
        phase_id: phase_id,
        worker_id: worker_id,
        sequence: sequence,
        tool_call_id: Map.get(payload, :tool_call_id),
        tool_name: Map.get(payload, :tool_name),
        status: Map.get(payload, :status),
        output: Map.get(payload, :output),
        artifact_paths: Map.get(payload, :artifact_paths, []),
        report_paths: Map.get(payload, :report_paths, []),
        exit_code: Map.get(payload, :exit_code),
        details: Map.get(payload, :details, %{})
      })
    end
  end

  defp append_worker_event(event_type, payload) do
    with {:ok, event} <-
           EventStore.append(%{
             stream_id: "worker:#{payload.run_id}:#{payload.worker_id}",
             event_type: event_type,
             payload: Map.put(payload, :observed_at, DateTime.utc_now()),
             metadata: %{
               correlation_id: payload.run_id,
               idempotency_key:
                 "#{event_type}:#{payload.run_id}:#{payload.worker_id}:#{payload.sequence}"
             }
           }) do
      {:ok, %{event: event, projection: ProjectionStore.snapshot()}}
    end
  end

  defp validate_sequence(run_id, worker_id, sequence) do
    expected = next_sequence(run_id, worker_id)

    if sequence == expected,
      do: :ok,
      else: {:error, {:out_of_order_sequence, expected: expected, actual: sequence}}
  end

  defp next_sequence(run_id, worker_id) do
    ProjectionStore.snapshot()
    |> get_in([:worker_sequences, "#{run_id}:#{worker_id}"])
    |> case do
      nil -> 1
      value -> value + 1
    end
  end

  defp worker_event_type("tool_call_finished"), do: "ToolCallFinished"
  defp worker_event_type("phase_completed"), do: "PhaseCompleted"
  defp worker_event_type("phase_failed"), do: "PhaseFailed"
  defp worker_event_type(type), do: Macro.camelize(type)

  defp required_binary(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  defp required_binary(_value, key), do: {:error, {:missing_or_invalid, key}}

  defp required_integer(value, _key) when is_integer(value), do: {:ok, value}
  defp required_integer(_value, key), do: {:error, {:missing_or_invalid, key}}

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {String.to_atom(key), atomize_value(value)}
      {key, value} -> {key, atomize_value(value)}
    end)
  end

  defp atomize_keys(_), do: %{}
  defp atomize_value(value) when is_map(value), do: atomize_keys(value)
  defp atomize_value(value) when is_list(value), do: Enum.map(value, &atomize_value/1)
  defp atomize_value(value), do: value
end
