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

  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "PhaseStarted" ->
        %State{
          state
          | exists?: true,
            phase_id: Aggregate.get(payload, :phase_id),
            run_id: Aggregate.get(payload, :run_id),
            status: "in_progress",
            terminal?: false
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
        %State{
          state
          | phase_id: Aggregate.get(payload, :phase_id),
            run_id: Aggregate.get(payload, :run_id),
            attempt: state.attempt + 1,
            status: "retrying",
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
      when type in ["phase.complete", "phase.fail", "phase.timeout", "phase.retry", "phase.skip", "phase.block"] do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, phase_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :phase_id), :phase_id),
         :ok <- require_started(state, type),
         :ok <- reject_terminal_for_non_retry(state, type) do
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
         payload: Map.merge(payload, %{run_id: run_id, phase_id: phase_id})
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

  defp reject_terminal_for_non_retry(%State{status: status}, "phase.retry")
      when status in ["failed", "timed_out", "retrying"],
      do: :ok

  defp reject_terminal_for_non_retry(%State{}, "phase.retry"), do: {:error, :phase_not_retryable}
  defp reject_terminal_for_non_retry(state, _type), do: reject_terminal(state)
end
