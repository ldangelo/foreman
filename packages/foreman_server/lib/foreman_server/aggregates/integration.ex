defmodule ForemanServer.Aggregates.Integration do
  @moduledoc "Integration aggregate: folds external ingestion/config events and validates dedupe."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  @impl true
  def initial_state, do: %{seen?: false, config: %{}}

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "IntegrationCommandIngested" ->
        state
        |> Map.merge(payload)
        |> Map.put(:seen?, true)
        |> Map.put(
          :dedupe_key,
          Aggregate.get(payload, :dedupe_key) || Aggregate.get(payload, :idempotency_key)
        )

      "IntegrationConfigured" ->
        state
        |> Map.put(:configured?, true)
        |> Map.put(
          :config,
          Map.merge(Map.get(state, :config, %{}), Aggregate.get(payload, :config, %{}))
        )

      "IntegrationSyncRequested" ->
        state |> Map.put(:sync_status, "requested") |> Map.put(:last_sync, payload)

      "IntegrationSyncCompleted" ->
        state |> Map.put(:sync_status, "completed") |> Map.put(:last_sync, payload)

      _ ->
        state
    end
  end

  @impl true
  def handle_command(state, %{type: "integration.ingest", payload: payload}) do
    with {:ok, dedupe_key} <-
           Aggregate.required_binary(Aggregate.get(payload, :dedupe_key), :dedupe_key),
         :ok <- require_new(state, dedupe_key) do
      {:ok,
       %{
         stream_id: "integration:#{dedupe_key}",
         event_type: "IntegrationCommandIngested",
         payload: Map.put_new(payload, :idempotency_key, dedupe_key)
       }}
    end
  end

  def handle_command(_state, %{type: "integration.configure", payload: payload}) do
    with {:ok, dedupe_key} <-
           Aggregate.required_binary(Aggregate.get(payload, :dedupe_key), :dedupe_key) do
      {:ok,
       %{
         stream_id: "integration:#{dedupe_key}",
         event_type: "IntegrationConfigured",
         payload: payload
       }}
    end
  end

  def handle_command(_state, %{type: type, payload: payload})
      when type in ["integration.sync.request", "integration.sync.complete"] do
    with {:ok, dedupe_key} <-
           Aggregate.required_binary(Aggregate.get(payload, :dedupe_key), :dedupe_key) do
      event_type =
        %{
          "integration.sync.request" => "IntegrationSyncRequested",
          "integration.sync.complete" => "IntegrationSyncCompleted"
        }[type]

      {:ok, %{stream_id: "integration:#{dedupe_key}", event_type: event_type, payload: payload}}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp require_new(%{seen?: true}, dedupe_key),
    do: {:error, {:duplicate_integration_event, dedupe_key}}

  defp require_new(_state, _dedupe_key), do: :ok
end
