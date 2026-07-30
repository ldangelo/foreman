defmodule ForemanServer.Aggregates.Phase do
  @moduledoc "Phase aggregate: validates per-run phase state transitions."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  defmodule State do
    @moduledoc false
    defstruct [:exists?, :run_id, :phase_id, :status, :attempt, :terminal?, phase_status: %{}]

    @type t :: %__MODULE__{
            exists?: boolean(),
            run_id: String.t() | nil,
            phase_id: String.t() | nil,
            status: String.t() | nil,
            attempt: non_neg_integer(),
            terminal?: boolean(),
            phase_status: %{optional(String.t()) => term()}
          }
  end

  @impl true
  def initial_state,
    do: %State{
      exists?: false,
      run_id: nil,
      phase_id: nil,
      status: nil,
      attempt: 0,
      terminal?: false
    }

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "PhaseStarted" ->
        run_id = Aggregate.get(payload, :run_id)
        phase_id = Aggregate.get(payload, :phase_id)

        %State{
          state
          | exists?: true,
            run_id: run_id,
            phase_id: phase_id,
            status: "in_progress",
            attempt: 0,
            terminal?: false
        }

      "PhaseCompleted" ->
        %State{state | status: "completed", terminal?: true}

      "PhaseFailed" ->
        %State{state | status: "failed", terminal?: true}

      "PhaseTimedOut" ->
        %State{state | status: "timed_out", terminal?: true}

      "PhaseRetried" ->
        current_attempt = Aggregate.get(payload, :attempt) || state.attempt

        %State{
          state
          | exists?: true,
            status: "retrying",
            attempt: current_attempt + 1,
            terminal?: false
        }

      "PhaseSkipped" ->
        %State{state | status: "skipped", terminal?: true}

      "PhaseNudged" ->
        nudge_count = Aggregate.get(payload, :nudge_count, 0)
        message = Aggregate.get(payload, :message)

        new_status =
          Map.put(state.phase_status, "last_nudge", %{count: nudge_count, message: message})

        %State{
          state
          | exists?: true,
            run_id: Aggregate.get(payload, :run_id) || state.run_id,
            phase_id: Aggregate.get(payload, :phase_id) || state.phase_id,
            phase_status: new_status
        }

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
      when type in ["phase.complete", "phase.fail", "phase.timeout", "phase.retry", "phase.skip"] do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, phase_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :phase_id), :phase_id),
         :ok <- require_started(state),
         :ok <- reject_terminal_for_non_retry(state, type) do
      event_type =
        %{
          "phase.complete" => "PhaseCompleted",
          "phase.fail" => "PhaseFailed",
          "phase.timeout" => "PhaseTimedOut",
          "phase.retry" => "PhaseRetried",
          "phase.skip" => "PhaseSkipped"
        }[type]

      {:ok,
       %{
         stream_id: "phase:#{run_id}:#{phase_id}",
         event_type: event_type,
         payload: Map.merge(payload, %{run_id: run_id, phase_id: phase_id})
       }}
    end
  end

  def handle_command(_state, %{type: "phase.nudge", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, phase_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :phase_id), :phase_id) do
      {:ok,
       %{
         stream_id: "phase:#{run_id}:#{phase_id}",
         event_type: "PhaseNudged",
         payload:
           Map.merge(payload, %{
             run_id: run_id,
             phase_id: phase_id,
             source: Aggregate.get(payload, :source, "elixir_overwatch")
           })
       }}
    end
  end
  def handle_command(_state, _command), do: :unhandled

  defp require_absent(%State{exists?: false}), do: :ok
  defp require_absent(%State{}), do: {:error, :phase_already_started}

  defp require_started(%State{exists?: true}), do: :ok
  defp require_started(%State{}), do: {:error, :phase_not_started}

  defp reject_terminal(%State{terminal?: true}), do: {:error, :phase_terminal}
  defp reject_terminal(%State{}), do: :ok

  defp reject_terminal_for_non_retry(%State{status: status}, "phase.retry")
       when status in ["failed", "timed_out", "retrying"],
       do: :ok

  defp reject_terminal_for_non_retry(%State{}, "phase.retry"), do: {:error, :phase_not_retryable}
  defp reject_terminal_for_non_retry(state, "phase.retry"), do: reject_terminal(state)
  defp reject_terminal_for_non_retry(state, _type), do: reject_terminal(state)
end
