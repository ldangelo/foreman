defmodule ForemanServer.Aggregates.OperatorIntervention do
  @moduledoc "Operator intervention aggregate: validates interruption and resume lifecycle per run."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  @impl true
  def initial_state do
    %{
      active?: false,
      status: nil,
      interruptions: 0
    }
  end

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "NeedsOperator" ->
        state
        |> Map.merge(payload)
        |> Map.put(:active?, true)
        |> Map.put(:status, "needs_operator")
        |> Map.update(:interruptions, 1, &(&1 + 1))

      "HumanInterruptionRecorded" ->
        state
        |> Map.merge(payload)
        |> Map.put(:active?, true)
        |> Map.put(:status, "interrupted")
        |> Map.update(:interruptions, 1, &(&1 + 1))

      "InteractiveRecoveryResumed" ->
        state
        |> Map.merge(payload)
        |> Map.put(:active?, false)
        |> Map.put(:status, "resume_requested")

      _ ->
        state
    end
  end

  @impl true
  def handle_command(state, %{type: type, payload: payload})
      when type in ["operator.needs", "operator.interrupt"] do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- reject_active(state) do
      event_type =
        if type == "operator.needs", do: "NeedsOperator", else: "HumanInterruptionRecorded"

      {:ok,
       %{
         stream_id: "operator:#{escape(run_id)}",
         event_type: event_type,
         payload: Map.put(payload, :run_id, run_id)
       }}
    end
  end

  def handle_command(state, %{type: "operator.resume", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_active(state) do
      {:ok,
       %{
         stream_id: "operator:#{escape(run_id)}",
         event_type: "InteractiveRecoveryResumed",
         payload: Map.put(payload, :run_id, run_id)
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp reject_active(%{active?: true}), do: {:error, :operator_intervention_active}
  defp reject_active(_state), do: :ok

  defp require_active(%{active?: true}), do: :ok
  defp require_active(_state), do: {:error, :operator_intervention_not_active}

  defp escape(value), do: String.replace(value, ":", "%3A")
end
