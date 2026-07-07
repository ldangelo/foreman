defmodule ForemanServer.Aggregates.Worker do
  @moduledoc "Worker aggregate: folds worker stream, validates monotonic event sequence and lifecycle."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  @terminal_events MapSet.new(["RunCompleted", "RunFailed", "WorkerExited"])

  @impl true
  def initial_state,
    do: %{exists?: false, last_sequence: -1, status: nil, tool_events: 0, assistant_messages: 0}

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)
    type = Aggregate.event_type(event)
    sequence = Aggregate.get(payload, :sequence, Map.get(state, :last_sequence))

    state =
      if is_integer(sequence),
        do: Map.put(state, :last_sequence, max(sequence, Map.get(state, :last_sequence, 0))),
        else: state

    case type do
      "WorkerStarted" ->
        state |> Map.merge(payload) |> Map.put(:exists?, true) |> Map.put(:status, "running")

      "WorkerHeartbeat" ->
        state |> Map.merge(payload) |> Map.put(:status, "heartbeat")

      "ToolCallFinished" ->
        state
        |> Map.merge(payload)
        |> Map.update(:tool_events, 1, &(&1 + 1))
        |> Map.put(:status, "running")

      "AssistantMessage" ->
        state
        |> Map.merge(payload)
        |> Map.update(:assistant_messages, 1, &(&1 + 1))
        |> Map.put(:status, "running")

      "WorkerStdout" ->
        state |> Map.merge(payload) |> Map.put(:status, "running")

      "WorkerStderr" ->
        state |> Map.merge(payload) |> Map.put(:status, "running")

      type when type in ["RunCompleted", "RunFailed", "WorkerExited"] ->
        state |> Map.merge(payload) |> Map.put(:status, "terminal") |> Map.put(:terminal?, true)

      _ ->
        state
    end
  end

  @impl true
  def handle_command(state, %{type: "worker.record", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, worker_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :worker_id), :worker_id),
         {:ok, event_type} <-
           Aggregate.required_binary(Aggregate.get(payload, :event_type), :event_type),
         :ok <- validate_next_sequence(state, Aggregate.get(payload, :sequence)),
         :ok <- allow_after_terminal(state, event_type) do
      {:ok,
       %{
         stream_id: "worker:#{run_id}:#{worker_id}",
         event_type: event_type,
         payload: Map.merge(payload, %{run_id: run_id, worker_id: worker_id})
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  def next_sequence(state), do: Map.get(state, :last_sequence, 0) + 1

  defp validate_next_sequence(_state, nil), do: :ok

  defp validate_next_sequence(state, sequence) when is_integer(sequence) do
    expected = next_sequence(state)

    if sequence == expected,
      do: :ok,
      else: {:error, {:out_of_order_sequence, expected: expected, actual: sequence}}
  end

  defp validate_next_sequence(_state, sequence),
    do: {:error, {:missing_or_invalid, {:sequence, sequence}}}

  defp allow_after_terminal(%{terminal?: true}, event_type) do
    if MapSet.member?(@terminal_events, event_type), do: :ok, else: {:error, :worker_terminal}
  end

  defp allow_after_terminal(_state, _event_type), do: :ok
end
