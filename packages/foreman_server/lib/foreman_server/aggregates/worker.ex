defmodule ForemanServer.Aggregates.Worker do
  @moduledoc "Worker aggregate: folds worker stream, validates monotonic event sequence and lifecycle."
  @behaviour ForemanServer.Aggregate
  alias ForemanServer.Aggregate
  alias ForemanServer.EventCodec
  alias ForemanServer.Events.{
    AssistantMessage,
    RunCompleted,
    RunFailed,
    ToolCallFinished,
    WorkerExited,
    WorkerHeartbeat,
    WorkerStarted,
    WorkerStderr,
    WorkerStdout,
    WorkerUnresponsive
  }

  defmodule State do
    @enforce_keys [:exists?, :worker_id, :run_id, :status, :terminal?]
    defstruct [
      :exists?,
      :worker_id,
      :run_id,
      :status,
      :terminal?,
      :session_id,
      :adapter,
      :prompt_path,
      last_sequence: -1,
      tool_events: 0,
      assistant_messages: 0,
      tool_names: [],
      artifact_paths: []
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
    type = Aggregate.event_type(event)
    payload = Aggregate.event_payload(event)
    # `event_type` identifies the event class and is the first argument to
    # `EventCodec.decode!/2` — it MUST NOT live inside the typed struct
    # payload. Strip both the atom and string forms of the key so the codec
    # sees only the struct's declared fields (regardless of whether the
    # caller dispatched with atom- or string-keyed payload).
    payload =
      payload
      |> Map.delete(:event_type)
      |> Map.delete("event_type")

    decoded = EventCodec.decode!(type, payload)
    apply_typed_event(state, decoded)
  end


  # ------------------------------------------------------------------
  defp apply_typed_event(state, %WorkerStarted{} = e) do
    new_state = bump_sequence(state, e.sequence)

    %State{
      new_state
      | exists?: true,
        worker_id: e.worker_id,
        run_id: e.run_id,
        session_id: e.session_id,
        adapter: e.adapter,
        prompt_path: e.prompt_path,
        tool_names: e.tool_names,
        artifact_paths: e.artifact_paths,
        status: "running",
        terminal?: false
    }
  end

  defp apply_typed_event(state, %WorkerHeartbeat{} = e) do
    new_state = bump_sequence(state, e.sequence)

    %State{
      new_state
      | worker_id: e.worker_id,
        run_id: e.run_id,
        status: "heartbeat"
    }
  end

  defp apply_typed_event(state, %WorkerUnresponsive{} = e) do
    new_state = bump_sequence(state, e.sequence)

    # Unresponsive is recoverable: a fresh `WorkerStarted` (re-launch)
    # or a `WorkerHeartbeat` after the worker reconnects must NOT be
    # rejected by `allow_after_terminal/2`. Reserve `terminal?: true`
    # for RunCompleted, RunFailed, and WorkerExited.
    %State{
      new_state
      | worker_id: e.worker_id,
        run_id: e.run_id,
        status: "unresponsive",
        terminal?: false
    }
  end

  defp apply_typed_event(state, %ToolCallFinished{} = e) do
    new_state = bump_sequence(state, e.sequence)

    %State{
      new_state
      | worker_id: e.worker_id,
        run_id: e.run_id,
        tool_events: new_state.tool_events + 1,
        status: "running"
    }
  end


  defp apply_typed_event(state, %AssistantMessage{} = e) do
    new_state = bump_sequence(state, e.sequence)

    %State{
      new_state
      | worker_id: e.worker_id,
        run_id: e.run_id,
        assistant_messages: new_state.assistant_messages + 1,
        status: "running"
    }
  end

  defp apply_typed_event(state, %WorkerStdout{} = e) do
    new_state = bump_sequence(state, e.sequence)

    %State{
      new_state
      | worker_id: e.worker_id,
        run_id: e.run_id,
        status: "running"
    }
  end

  defp apply_typed_event(state, %WorkerStderr{} = e) do
    new_state = bump_sequence(state, e.sequence)

    %State{
      new_state
      | worker_id: e.worker_id,
        run_id: e.run_id,
        status: "running"
    }
  end

  defp apply_typed_event(state, %WorkerExited{} = e) do
    new_state = bump_sequence(state, e.sequence)

    %State{
      new_state
      | worker_id: e.worker_id,
        run_id: e.run_id || new_state.run_id,
        status: "terminal",
        terminal?: true
    }
  end

  defp apply_typed_event(state, %RunCompleted{} = e) do
    new_state = bump_sequence(state, e.sequence)

    %State{
      new_state
      | run_id: e.run_id || new_state.run_id,
        status: "terminal",
        terminal?: true
    }
  end

  defp apply_typed_event(state, %RunFailed{} = e) do
    new_state = bump_sequence(state, e.sequence)

    %State{
      new_state
      | run_id: e.run_id || new_state.run_id,
        status: "terminal",
        terminal?: true
    }
  end

  defp bump_sequence(state, nil), do: state

  defp bump_sequence(state, sequence) when is_integer(sequence),
    do: %State{state | last_sequence: max(sequence, state.last_sequence)}

  @impl true
  def handle_command(state, %{type: "worker.record", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, worker_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :worker_id), :worker_id),
         {:ok, event_type} <-
           Aggregate.required_binary(Aggregate.get(payload, :event_type), :event_type),
         :ok <- validate_next_sequence(state, Aggregate.get(payload, :sequence)),
         :ok <- allow_after_terminal(state, event_type),
         :ok <- validate_typed_event(event_type, payload) do
      {:ok,
       %{
         stream_id: "worker:#{run_id}:#{worker_id}",
         event_type: event_type,
         payload: payload
       }}
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

  defp allow_after_terminal(%State{terminal?: true}, event_type) do
    if MapSet.member?(@terminal_events, event_type), do: :ok, else: {:error, :worker_terminal}
  end

  defp allow_after_terminal(_state, _event_type), do: :ok

  # Strictly validate the event payload against the typed-event contract.
  # `EventCodec.decode!/2` raises on:
  #   * unknown event_type
  #   * mismatched struct
  #   * missing `@enforce_keys` (e.g. session_id/adapter/prompt_path on WorkerStarted)
  #   * unknown fields
  # We surface those as `{:error, {:malformed_event, message}}` so the
  # dispatcher never persists a payload that would later fail replay.
  #
  # `event_type` identifies the event class and is the first argument to
  # `decode!/2` — it MUST NOT live inside the typed struct payload.
  # Strip both atom and string forms (same convention as `apply_event/2`)
  # so the codec only sees declared fields.
  defp validate_typed_event(event_type, payload) do
    cleaned =
      payload
      |> Map.delete(:event_type)
      |> Map.delete("event_type")

    _ = EventCodec.decode!(event_type, cleaned)
    :ok
  rescue
    e in ArgumentError -> {:error, {:malformed_event, Exception.message(e)}}
  end
end
