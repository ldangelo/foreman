defmodule ForemanServer.Aggregates.Recovery do
  @moduledoc "Recovery aggregate: preserves observation-before-action recovery chains."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  defmodule RecoveryEntry do
    @moduledoc "An observation or action record in the recovery chain."
    @enforce_keys [:event_type, :run_id]
    defstruct [:event_type, :run_id, metadata: %{}]
  end

  defmodule State do
    @enforce_keys [:exists?]
    defstruct [:exists?, :run_id, :status, attempts: 0, observations: [], actions: []]
  end

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
  def initial_state,
    do: %State{
      exists?: false,
      run_id: nil,
      status: nil,
      attempts: 0,
      observations: [],
      actions: []
    }

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)
    type = Aggregate.event_type(event)
    run_id = Aggregate.get(payload, :run_id)
    metadata = Map.drop(payload, [:run_id])
    record = %RecoveryEntry{event_type: type, run_id: run_id, metadata: metadata}

    cond do
      MapSet.member?(@observation_events, type) ->
        %State{
          state
          | exists?: true,
            run_id: run_id,
            observations: state.observations ++ [record],
            status: "observed"
        }

      MapSet.member?(@action_events, type) ->
        %State{
          state
          | exists?: true,
            run_id: run_id,
            actions: state.actions ++ [record],
            attempts: state.attempts + 1,
            status: recovery_status(type)
        }

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

  defp require_observation_for_action(%State{observations: obs}, _type)
       when length(obs) > 0,
       do: :ok

  defp require_observation_for_action(_state, _type), do: {:error, :recovery_requires_observation}

  defp reject_resolved(%State{status: "resolved"}), do: {:error, :recovery_resolved}
  defp reject_resolved(_state), do: :ok

  defp recovery_status("NeedsOperator"), do: "needs_operator"
  defp recovery_status("RecoveryResolved"), do: "resolved"
  defp recovery_status(_type), do: "recovering"
end
