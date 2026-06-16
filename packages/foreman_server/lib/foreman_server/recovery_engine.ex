defmodule ForemanServer.RecoveryEngine do
  @moduledoc "Worker recovery and external-state reconciliation engine."

  alias ForemanServer.EventStore

  @fresh_heartbeat_seconds 60

  @spec reconcile(map()) :: {:ok, map()} | {:error, term()}
  def reconcile(observation) when is_map(observation) do
    observation = atomize_keys(observation)

    with {:ok, _run_id} <- required_binary(Map.get(observation, :run_id), :run_id),
         {:ok, _phase_id} <- required_binary(Map.get(observation, :phase_id), :phase_id),
         {:ok, _worker_id} <- required_binary(Map.get(observation, :worker_id), :worker_id),
         {:ok, observed} <- append("ExternalWorkerObserved", observation) do
      decision = decide(observation)

      with {:ok, event} <- append(decision.event_type, Map.merge(observation, decision.payload)) do
        {:ok, %{observed: observed, event: event, decision: decision.action}}
      end
    end
  end

  defp decide(observation) do
    cond do
      fresh_matching_heartbeat?(observation) ->
        %{
          action: :reattach,
          event_type: "WorkerReattached",
          payload: %{recovery_action: "reattach", attach: Map.get(observation, :attach, %{})}
        }

      restart_allowed?(observation) ->
        %{
          action: :restart,
          event_type: "WorkerRestarted",
          payload: %{
            recovery_action: "restart_phase",
            checkpoint: Map.get(observation, :checkpoint)
          }
        }

      true ->
        %{
          action: :needs_operator,
          event_type: "NeedsOperator",
          payload: %{
            recovery_action: "needs_operator",
            conflicts: Map.get(observation, :conflicts, [])
          }
        }
    end
  end

  defp fresh_matching_heartbeat?(observation) do
    Map.get(observation, :external_state, %{}) |> Map.get(:worker_alive, false) &&
      heartbeat_age_seconds(observation) <= @fresh_heartbeat_seconds &&
      matching_metadata?(observation)
  end

  defp matching_metadata?(observation) do
    heartbeat = Map.get(observation, :heartbeat, %{})

    Enum.all?([:run_id, :phase_id, :worker_id], fn key ->
      Map.get(heartbeat, key, Map.get(observation, key)) == Map.get(observation, key)
    end)
  end

  defp restart_allowed?(observation) do
    policy = Map.get(observation, :restart_policy, %{})
    checkpoint = Map.get(observation, :checkpoint, %{})

    Map.get(policy, :allow_restart, false) &&
      (Map.get(checkpoint, :idempotent, false) || Map.get(checkpoint, :safe, false))
  end

  defp heartbeat_age_seconds(%{heartbeat_age_seconds: age}) when is_number(age), do: age

  defp heartbeat_age_seconds(%{last_heartbeat_at: %DateTime{} = last}) do
    DateTime.diff(DateTime.utc_now(), last, :second)
  end

  defp heartbeat_age_seconds(%{last_heartbeat_at: value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.diff(DateTime.utc_now(), dt, :second)
      _ -> @fresh_heartbeat_seconds + 1
    end
  end

  defp heartbeat_age_seconds(_), do: @fresh_heartbeat_seconds + 1

  defp append(event_type, %{run_id: run_id, worker_id: worker_id} = payload) do
    EventStore.append(%{
      stream_id: "recovery:#{run_id}:#{worker_id}",
      event_type: event_type,
      payload: Map.put(payload, :observed_at, DateTime.utc_now()),
      metadata: %{
        correlation_id: run_id,
        idempotency_key:
          "#{event_type}:#{run_id}:#{worker_id}:#{System.unique_integer([:positive])}"
      }
    })
  end

  defp required_binary(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  defp required_binary(_value, key), do: {:error, {:missing_or_invalid, key}}

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {String.to_atom(key), atomize_value(value)}
      {key, value} -> {key, atomize_value(value)}
    end)
  end

  defp atomize_value(value) when is_map(value), do: atomize_keys(value)
  defp atomize_value(value) when is_list(value), do: Enum.map(value, &atomize_value/1)
  defp atomize_value(value), do: value
end
