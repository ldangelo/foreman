defmodule ForemanServer.Aggregates.Recovery do
  @moduledoc "Recovery aggregate: preserves observation-before-action recovery chains."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  @observation_events MapSet.new([
                        "WorkerFailureSimulated",
                        "WorkerRecoveryRequired",
                        "ExternalWorkerObserved"
                      ])
  @action_events MapSet.new([
                   "WorkerReattached",
                   "WorkerRestarted",
                   "NeedsOperator",
                   "RecoveryResolved"
                 ])

  @impl true
  def initial_state, do: %{observations: [], actions: [], status: nil, attempts: 0}

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)
    type = Aggregate.event_type(event)
    record = Map.put(payload, :event_type, type)

    cond do
      MapSet.member?(@observation_events, type) ->
        state
        |> update_in([:observations], &((&1 || []) ++ [record]))
        |> Map.put(:status, "observed")

      MapSet.member?(@action_events, type) ->
        state
        |> update_in([:actions], &((&1 || []) ++ [record]))
        |> Map.update(:attempts, 1, &(&1 + 1))
        |> Map.put(:status, recovery_status(type))

      true ->
        state
    end
  end

  @impl true
  def handle_command(state, %{type: type, payload: payload})
      when type in [
             "recovery.observe_external_worker",
             "recovery.require",
             "recovery.reattach",
             "recovery.restart",
             "recovery.needs_operator",
             "recovery.resolve"
           ] do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_observation_for_action(state, type),
         :ok <- reject_resolved(state) do
      event_type =
        %{
          "recovery.observe_external_worker" => "ExternalWorkerObserved",
          "recovery.require" => "WorkerRecoveryRequired",
          "recovery.reattach" => "WorkerReattached",
          "recovery.restart" => "WorkerRestarted",
          "recovery.needs_operator" => "NeedsOperator",
          "recovery.resolve" => "RecoveryResolved"
        }[type]

      {:ok,
       %{
         stream_id: "recovery:#{run_id}",
         event_type: event_type,
         payload: Map.put(payload, :run_id, run_id)
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp require_observation_for_action(_state, type)
       when type in ["recovery.observe_external_worker", "recovery.require"],
       do: :ok

  defp require_observation_for_action(%{observations: observations}, _type)
       when length(observations) > 0,
       do: :ok

  defp require_observation_for_action(_state, _type), do: {:error, :recovery_requires_observation}

  defp reject_resolved(%{status: "resolved"}), do: {:error, :recovery_resolved}
  defp reject_resolved(_state), do: :ok

  defp recovery_status("NeedsOperator"), do: "needs_operator"
  defp recovery_status("RecoveryResolved"), do: "resolved"
  defp recovery_status(_type), do: "recovering"
end
