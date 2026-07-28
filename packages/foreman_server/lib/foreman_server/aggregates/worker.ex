defmodule ForemanServer.Aggregates.Worker do
  @moduledoc "Worker aggregate: folds worker stream, validates monotonic event sequence and lifecycle."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  defmodule State do
    @enforce_keys [:exists?, :worker_id, :run_id, :status, :terminal?]
    defstruct [
      :exists?,
      :worker_id,
      :run_id,
      :status,
      :terminal?,
      last_sequence: -1,
      tool_events: 0,
      assistant_messages: 0
    ]
  end

  @terminal_events MapSet.new(["RunCompleted", "RunFailed", "WorkerExited"])

  @impl true
  def initial_state,
    do: %State{
      exists?: false,
      worker_id: nil,
      run_id: nil,
      last_sequence: -1,
      status: nil,
      tool_events: 0,
      assistant_messages: 0,
      terminal?: false
    }

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)
    type = Aggregate.event_type(event)
    sequence = Aggregate.get(payload, :sequence)

    new_state =
      if is_integer(sequence) do
        %State{state | last_sequence: max(sequence, state.last_sequence)}
      else
        state
      end

    case type do
      "WorkerStarted" ->
        %State{
          new_state
          | exists?: true,
            worker_id: Aggregate.get(payload, :worker_id),
            run_id: Aggregate.get(payload, :run_id),
            status: "running",
            terminal?: false
        }

      "WorkerHeartbeat" ->
        %State{
          new_state
          | worker_id: Aggregate.get(payload, :worker_id),
            run_id: Aggregate.get(payload, :run_id),
            status: "heartbeat"
        }

      "ToolCallFinished" ->
        %State{
          new_state
          | worker_id: Aggregate.get(payload, :worker_id),
            run_id: Aggregate.get(payload, :run_id),
            tool_events: new_state.tool_events + 1,
            status: "running"
        }

      "AssistantMessage" ->
        %State{
          new_state
          | worker_id: Aggregate.get(payload, :worker_id),
            run_id: Aggregate.get(payload, :run_id),
            assistant_messages: new_state.assistant_messages + 1,
            status: "running"
        }

      "WorkerStdout" ->
        %State{
          new_state
          | worker_id: Aggregate.get(payload, :worker_id),
            run_id: Aggregate.get(payload, :run_id),
            status: "running"
        }

      "WorkerStderr" ->
        %State{
          new_state
          | worker_id: Aggregate.get(payload, :worker_id),
            run_id: Aggregate.get(payload, :run_id),
            status: "running"
        }

      type when type in ["RunCompleted", "RunFailed", "WorkerExited"] ->
        %State{
          new_state
          | worker_id: Aggregate.get(payload, :worker_id),
            run_id: Aggregate.get(payload, :run_id),
            status: "terminal",
            terminal?: true
        }

      _ ->
        new_state
    end
  end

  @terminal_events MapSet.new(["WorkerExited"])

  @impl true
  def handle_command(state, %{type: type, payload: payload})
      when type in [
             "worker.start",
             "worker.heartbeat",
             "worker.exit",
             "worker.message",
             "worker.stdout.append",
             "worker.stderr.append"
           ] do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, worker_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :worker_id), :worker_id),
         :ok <- validate_next_sequence(state, Aggregate.get(payload, :sequence)),
         :ok <- allow_after_terminal(state, type) do
      event =
        case type do
          "worker.start" -> %ForemanServer.Events.WorkerStarted{run_id: run_id, worker_id: worker_id}
          "worker.heartbeat" -> %ForemanServer.Events.WorkerHeartbeat{run_id: run_id, worker_id: worker_id}
          "worker.exit" -> %ForemanServer.Events.WorkerExited{run_id: run_id, worker_id: worker_id}
          "worker.message" -> %ForemanServer.Events.AssistantMessage{run_id: run_id, worker_id: worker_id}
          "worker.stdout.append" -> %ForemanServer.Events.WorkerStdout{run_id: run_id, worker_id: worker_id}
          "worker.stderr.append" -> %ForemanServer.Events.WorkerStderr{run_id: run_id, worker_id: worker_id}
        end

      {:ok, event}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  def next_sequence(state), do: state.last_sequence + 1

  defp validate_next_sequence(_state, nil), do: :ok

  defp validate_next_sequence(state, sequence) when is_integer(sequence) do
    expected = next_sequence(state)

    if sequence == expected,
      do: :ok,
      else: {:error, {:out_of_order_sequence, expected: expected, actual: sequence}}
  end

  defp validate_next_sequence(_state, sequence),
    do: {:error, {:missing_or_invalid, {:sequence, sequence}}}

  # Only worker.exit may be sent after the worker is terminal.
  defp allow_after_terminal(%State{terminal?: true}, type) do
    if type == "worker.exit", do: :ok, else: {:error, :worker_terminal}
  end

  defp allow_after_terminal(_state, _type), do: :ok
end
