defmodule ForemanServer.Aggregates.Phase do
  @moduledoc "Phase aggregate: validates per-run phase state transitions."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  defmodule State do
    @enforce_keys [:exists?, :phase_id, :run_id, :status, :terminal?]
    defstruct [:exists?, :phase_id, :run_id, :status, :terminal?, attempt: 0]
  end

  @impl true
  def initial_state,
    do: %State{
      exists?: false,
      phase_id: nil,
      run_id: nil,
      status: nil,
      terminal?: false,
      attempt: 0
    }

  @impl true
  def apply_event(%State{} = state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "PhaseStarted" ->
        %State{
          state
          | exists?: true,
            phase_id: Aggregate.get(payload, :phase_id),
            run_id: Aggregate.get(payload, :run_id),
            status: "in_progress",
            terminal?: false,
            attempt: Aggregate.get(payload, :attempt, state.attempt)
        }

      "PhaseCompleted" ->
        %State{state | status: "completed", terminal?: true}

      "PhaseFailed" ->
        %State{state | status: "failed", terminal?: true}

      "PhaseTimedOut" ->
        %State{state | status: "timed_out", terminal?: true}

      "PhaseBlocked" ->
        %State{state | status: "blocked", terminal?: true}

      "PhaseRetried" ->
        resumed? = Aggregate.get(payload, :reason) == "resumed"

        %State{
          state
          | phase_id: Aggregate.get(payload, :phase_id),
            run_id: Aggregate.get(payload, :run_id),
            attempt: Aggregate.get(payload, :attempt, state.attempt + 1),
            status: if(resumed?, do: "in_progress", else: "retrying"),
            terminal?: false
        }

      "PhaseSkipped" ->
        %State{state | status: "skipped", terminal?: true}

      _ ->
        state
    end
  end

  @impl true
  def handle_command(state, %{type: "phase.start", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, phase_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :phase_id), :phase_id),
         :ok <- require_absent(state),
         :ok <- reject_terminal(state) do
      {:ok,
       %{
         stream_id: "phase:#{run_id}:#{phase_id}",
         event_type: "PhaseStarted",
         payload: Map.merge(payload, %{run_id: run_id, phase_id: phase_id})
       }}
    end
  end

  def handle_command(state, %{type: type, payload: payload})
      when type in [
             "phase.complete",
             "phase.fail",
             "phase.timeout",
             "phase.retry",
             "phase.skip",
             "phase.block"
           ] do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, phase_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :phase_id), :phase_id),
         :ok <- require_started(state, type),
         :ok <- reject_terminal_for_non_retry(state, type, payload) do
      event_type =
        %{
          "phase.complete" => "PhaseCompleted",
          "phase.fail" => "PhaseFailed",
          "phase.timeout" => "PhaseTimedOut",
          "phase.retry" => "PhaseRetried",
          "phase.skip" => "PhaseSkipped",
          "phase.block" => "PhaseBlocked"
        }[type]

      {:ok,
       %{
         stream_id: "phase:#{run_id}:#{phase_id}",
         event_type: event_type,
         payload:
           type
           |> event_payload(payload, run_id, phase_id)
           |> stamp_attempt(type, state)
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp require_absent(%State{exists?: true}), do: {:error, :phase_already_started}
  defp require_absent(_state), do: :ok

  defp require_started(%State{exists?: true}, _type), do: :ok
  defp require_started(_state, _type), do: {:error, :phase_not_started}

  defp reject_terminal(%State{terminal?: true}), do: {:error, :phase_terminal}
  defp reject_terminal(_state), do: :ok

  # `PhaseRetried` is decoded strictly, so only its declared fields reach the
  # stream (AGENTS.md 5.4b); an absent optional field stays absent.
  defp event_payload("phase.retry", payload, run_id, phase_id) do
    for key <- [:index, :reason, :prior_worktree_discarded],
        value = Aggregate.get(payload, key),
        value != nil,
        into: %{run_id: run_id, phase_id: phase_id},
        do: {key, value}
  end

  defp event_payload(_type, payload, run_id, phase_id),
    do: Map.merge(payload, %{run_id: run_id, phase_id: phase_id})

  # The attempt comes from the stream, never from the caller.
  defp stamp_attempt(payload, "phase.retry", %State{attempt: attempt}),
    do: Map.put(payload, :attempt, attempt + 1)

  defp stamp_attempt(payload, _type, _state), do: payload

  defp reject_terminal_for_non_retry(%State{status: "in_progress"}, "phase.retry", payload) do
    if Aggregate.get(payload, :reason) == "resumed",
      do: :ok,
      else: {:error, :phase_not_retryable}
  end

  # `resumed` is the restart of an in_progress phase; a failed, timed-out or
  # retrying phase takes an ordinary retry only.
  defp reject_terminal_for_non_retry(%State{status: status}, "phase.retry", payload)
       when status in ["failed", "timed_out", "retrying"] do
    if Aggregate.get(payload, :reason) == "resumed",
      do: {:error, :phase_not_retryable},
      else: :ok
  end

  defp reject_terminal_for_non_retry(%State{}, "phase.retry", _payload),
    do: {:error, :phase_not_retryable}

  defp reject_terminal_for_non_retry(state, _type, _payload), do: reject_terminal(state)
end
