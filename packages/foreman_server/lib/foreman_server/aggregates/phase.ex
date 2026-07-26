defmodule ForemanServer.Aggregates.Phase do
  @moduledoc "Phase aggregate: validates per-run phase state transitions."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  @impl true
  def initial_state, do: %{exists?: false, status: nil, attempt: 0}

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "PhaseStarted" ->
        state |> Map.merge(payload) |> Map.put(:exists?, true) |> Map.put(:status, "in_progress")

      "PhaseCompleted" ->
        state |> Map.merge(payload) |> Map.put(:status, "completed") |> Map.put(:terminal?, true)

      "PhaseFailed" ->
        state |> Map.merge(payload) |> Map.put(:status, "failed") |> Map.put(:terminal?, true)

      "PhaseTimedOut" ->
        state |> Map.merge(payload) |> Map.put(:status, "timed_out") |> Map.put(:terminal?, true)

      "PhaseRetried" ->
        state
        |> Map.merge(payload)
        |> Map.put(:exists?, true)
        |> Map.update(:attempt, 1, &(&1 + 1))
        |> Map.put(:status, "retrying")
        |> Map.put(:terminal?, false)

      "PhaseSkipped" ->
        state |> Map.merge(payload) |> Map.put(:status, "skipped") |> Map.put(:terminal?, true)

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
         :ok <- require_started(state, type),
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

  def handle_command(_state, _command), do: :unhandled

  defp require_absent(%{exists?: true}), do: {:error, :phase_already_started}
  defp require_absent(_state), do: :ok

  defp require_started(%{exists?: true}, _type), do: :ok
  defp require_started(_state, _type), do: {:error, :phase_not_started}

  defp reject_terminal(%{terminal?: true}), do: {:error, :phase_terminal}
  defp reject_terminal(_state), do: :ok

  defp reject_terminal_for_non_retry(%{status: status}, "phase.retry")
       when status in ["failed", "timed_out", "retrying"],
       do: :ok

  defp reject_terminal_for_non_retry(_state, "phase.retry"), do: {:error, :phase_not_retryable}
  defp reject_terminal_for_non_retry(state, _type), do: reject_terminal(state)
end
