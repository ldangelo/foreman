defmodule ForemanServer.Aggregates.OperatorIntervention do
  @moduledoc "Operator intervention aggregate: validates interruption and resume lifecycle per run, with per-workflow timeout (JSI-T009)."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  defmodule State do
    defstruct [:active?, :status, :run_id, :deadline_at_ms, :intervention_id, interruptions: 0]
  end

  @impl true
  def initial_state do
    %State{
      active?: false,
      status: nil,
      interruptions: 0,
      run_id: nil,
      deadline_at_ms: nil,
      intervention_id: nil
    }
  end

  @impl true
  def apply_event(%State{} = state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "NeedsOperator" ->
        %State{
          state
          | active?: true,
            status: "needs_operator",
            interruptions: state.interruptions + 1,
            run_id: Aggregate.get(payload, :run_id),
            deadline_at_ms: Aggregate.get(payload, :deadline_at_ms),
            intervention_id: Aggregate.get(payload, :intervention_id)
        }

      "HumanInterruptionRecorded" ->
        %State{
          state
          | active?: true,
            status: "interrupted",
            interruptions: state.interruptions + 1,
            run_id: Aggregate.get(payload, :run_id)
        }

      "InteractiveRecoveryResumed" ->
        %State{
          state
          | active?: false,
            status: "resume_requested",
            run_id: Aggregate.get(payload, :run_id)
        }

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

      full_payload =
        payload
        |> Map.put(:run_id, run_id)
        |> maybe_put(:deadline_at_ms, Aggregate.get(payload, :deadline_at_ms))
        |> maybe_put(:intervention_id, Aggregate.get(payload, :intervention_id))

      {:ok,
       %{
         stream_id: "operator:#{escape(run_id)}",
         event_type: event_type,
         payload: full_payload
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

  @doc """
  Return the active interventions whose deadline has passed
  (JSI-T009). The scheduler calls this with the current
  timestamp and emits `run.block` for each result. Interventions
  without a deadline (deadline_at_ms == nil) are never expired.
  """
  @spec expired_interventions([State.t()], integer()) :: [State.t()]
  def expired_interventions(states, now_ms) do
    Enum.filter(states, fn %State{active?: active?, deadline_at_ms: deadline_at_ms} ->
      active? and not is_nil(deadline_at_ms) and now_ms >= deadline_at_ms
    end)
  end

  defp reject_active(%State{active?: true}), do: {:error, :operator_intervention_active}
  defp reject_active(_state), do: :ok

  defp require_active(%State{active?: true}), do: :ok
  defp require_active(_state), do: {:error, :operator_intervention_not_active}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp escape(value), do: String.replace(value, ":", "%3A")
end
