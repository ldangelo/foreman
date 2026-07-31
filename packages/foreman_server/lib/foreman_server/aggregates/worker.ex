defmodule ForemanServer.Aggregates.Worker do
  @moduledoc "Worker aggregate: folds worker stream, validates monotonic event sequence and lifecycle."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  # Terminal events: after these the worker stream is sealed except for the event itself
  @terminal_events MapSet.new(["RunCompleted", "RunFailed", "WorkerExited", "WorkerUnresponsive", "WorkerCrashed"])

  # Events allowed after terminal: terminal events plus TaskUpdated (a terminal-run lifecycle ack).
  @events_allowed_after_terminal MapSet.put(@terminal_events, "TaskUpdated")
  defmodule State do
    defstruct [
      :exists?,
      :run_id,
      :worker_id,
      :phase_id,
      :last_sequence,
      :status,
      :adapter,
      tool_events: 0,
      assistant_messages: 0,
      terminal?: false
    ]
  end

  @impl true
  def initial_state, do: %State{exists?: false, last_sequence: -1, status: nil}

  # ══════════════════════════════════════════════════════════════════════════════
  # apply_event — three clause groups
  #
  #   Group 1 — Envelope unwrappers (for replay via Aggregate.decode_for_fold):
  #     %ForemanServer.Event{payload: %WorkerX{}} → direct typed clause
  #
  #   Group 2 — Direct typed struct clauses (tests and direct calls):
  #     %WorkerX{} → state mutation + update_sequence
  #
  #   Group 3 — Legacy fallback (plain-map payloads, cross-domain events,
  #     pre-migration stored events):
  #     any event → string-type case + Aggregate.get field access
  # ══════════════════════════════════════════════════════════════════════════════

  # ── Group 1: Envelope unwrappers ─────────────────────────────────────────────
  @impl true
  def apply_event(state, %ForemanServer.Event{payload: %ForemanServer.Events.WorkerStarted{} = e}),
    do: apply_event(state, e)

  def apply_event(state, %ForemanServer.Event{payload: %ForemanServer.Events.WorkerHeartbeat{} = e}),
    do: apply_event(state, e)

  def apply_event(state, %ForemanServer.Event{payload: %ForemanServer.Events.ToolCallFinished{} = e}),
    do: apply_event(state, e)

  def apply_event(state, %ForemanServer.Event{payload: %ForemanServer.Events.AssistantMessage{} = e}),
    do: apply_event(state, e)

  def apply_event(state, %ForemanServer.Event{payload: %ForemanServer.Events.WorkerStdout{} = e}),
    do: apply_event(state, e)

  def apply_event(state, %ForemanServer.Event{payload: %ForemanServer.Events.WorkerStderr{} = e}),
    do: apply_event(state, e)

  def apply_event(state, %ForemanServer.Event{payload: %ForemanServer.Events.WorkerExited{} = e}),
    do: apply_event(state, e)

  def apply_event(state, %ForemanServer.Event{payload: %ForemanServer.Events.WorkerUnresponsive{} = e}),
    do: apply_event(state, e)

  def apply_event(state, %ForemanServer.Event{payload: %ForemanServer.Events.WorkerCrashed{} = e}),
    do: apply_event(state, e)

  # ── Group 2: Direct typed struct clauses ────────────────────────────────────
  @impl true
  def apply_event(state, %ForemanServer.Events.WorkerStarted{} = e) do
    state
    |> update_sequence(e)
    |> then(fn s ->
      %State{s |
        exists?: true,
        run_id: e.run_id,
        worker_id: e.worker_id,
        phase_id: e.phase_id,
        adapter: e.adapter,
        status: "running",
        terminal?: false
      }
    end)
  end

  @impl true
  def apply_event(state, %ForemanServer.Events.WorkerHeartbeat{} = e) do
    %State{state | status: "heartbeat"} |> update_sequence(e)
  end

  @impl true
  def apply_event(state, %ForemanServer.Events.ToolCallFinished{} = e) do
    %State{state | tool_events: state.tool_events + 1, status: "running"}
    |> update_sequence(e)
  end

  @impl true
  def apply_event(state, %ForemanServer.Events.AssistantMessage{} = e) do
    %State{state | assistant_messages: state.assistant_messages + 1, status: "running"}
    |> update_sequence(e)
  end

  @impl true
  def apply_event(state, %ForemanServer.Events.WorkerStdout{} = e) do
    %State{state | status: "running"} |> update_sequence(e)
  end

  @impl true
  def apply_event(state, %ForemanServer.Events.WorkerStderr{} = e) do
    %State{state | status: "running"} |> update_sequence(e)
  end

  @impl true
  def apply_event(state, %ForemanServer.Events.WorkerExited{} = e) do
    %State{state | status: "terminal", terminal?: true} |> update_sequence(e)
  end

  @impl true
  def apply_event(state, %ForemanServer.Events.WorkerUnresponsive{} = e) do
    %State{state | status: "unresponsive", terminal?: true} |> update_sequence(e)
  end

  @impl true
  def apply_event(state, %ForemanServer.Events.WorkerCrashed{} = e) do
    %State{state | status: "crashed", terminal?: true} |> update_sequence(e)
  end

  # ── Group 3: Legacy fallback ────────────────────────────────────────────────
  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)
    type = Aggregate.event_type(event)

    state = update_sequence(state, payload)

    case type do
      "WorkerStarted" ->
        %State{state |
          exists?: true,
          run_id: Aggregate.get(payload, :run_id),
          worker_id: Aggregate.get(payload, :worker_id),
          phase_id: Aggregate.get(payload, :phase_id),
          adapter: Aggregate.get(payload, :adapter),
          status: "running",
          terminal?: false
        }

      "WorkerHeartbeat" ->
        %State{state | status: "heartbeat"}

      "ToolCallFinished" ->
        %State{state | tool_events: state.tool_events + 1, status: "running"}

      "AssistantMessage" ->
        %State{state | assistant_messages: state.assistant_messages + 1, status: "running"}

      "WorkerStdout" ->
        %State{state | status: "running"}

      "WorkerStderr" ->
        %State{state | status: "running"}

      type when type in ["RunCompleted", "RunFailed", "WorkerExited"] ->
        %State{state | status: "terminal", terminal?: true}

      "WorkerUnresponsive" ->
        %State{state | status: "unresponsive", terminal?: true}

      "WorkerCrashed" ->
        %State{state | status: "crashed", terminal?: true}

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
      # Decode the command payload into a typed struct (via from_payload/1 for known
      # event types, or leave as map for unknown/legacy).  Strip command-only
      # :event_type before storing — it lives in the envelope, not the payload.
      decoded_payload =
        payload
        |> then(&ForemanServer.EventCodec.decode!(event_type, &1))
        |> Map.delete(:event_type)

      {:ok,
       %{
         stream_id: "worker:#{run_id}:#{worker_id}",
         event_type: event_type,
         payload: Map.merge(decoded_payload, %{run_id: run_id, worker_id: worker_id})
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  def next_sequence(state), do: (state.last_sequence || 0) + 1

  defp update_sequence(state, payload) do
    seq = Aggregate.get(payload, :sequence)
    if is_integer(seq) do
      %State{state | last_sequence: max(seq, state.last_sequence || -1)}
    else
      state
    end
  end

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
    if MapSet.member?(@events_allowed_after_terminal, event_type),
      do: :ok,
      else: {:error, :worker_terminal}
  end

  defp allow_after_terminal(_state, _event_type), do: :ok
end
