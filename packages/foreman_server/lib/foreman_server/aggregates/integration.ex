defmodule ForemanServer.Aggregates.Integration do
  @moduledoc "Integration aggregate: folds external ingestion/config events and validates dedupe."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  defmodule State do
    @enforce_keys [:seen?]
    defstruct [:seen?, :dedupe_key, :configured?, :sync_status, config: %{}, last_sync: nil]
  end

  @impl true
  def initial_state,
    do: %State{
      seen?: false,
      dedupe_key: nil,
      configured?: false,
      sync_status: nil,
      config: %{},
      last_sync: nil
    }

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "IntegrationCommandIngested" ->
        dedupe_key =
          Aggregate.get(payload, :dedupe_key) ||
            Aggregate.get(payload, :idempotency_key)

        %State{
          state
          | seen?: true,
            dedupe_key: dedupe_key,
            config: Map.merge(state.config, Map.get(payload, :config, %{}))
        }

      "IntegrationConfigured" ->
        %State{
          state
          | configured?: true,
            config: Map.merge(state.config, Map.get(payload, :config, %{}))
        }

      "IntegrationSyncRequested" ->
        %State{state | sync_status: "requested", last_sync: payload}

      "IntegrationSyncCompleted" ->
        %State{state | sync_status: "completed", last_sync: payload}

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
       %ForemanServer.Events.IntegrationCommandIngested{
         dedupe_key: dedupe_key,
         config: Aggregate.get(payload, :config)
       }}
    end
  end

  def handle_command(_state, %{type: "integration.configure", payload: payload}) do
    with {:ok, dedupe_key} <-
           Aggregate.required_binary(Aggregate.get(payload, :dedupe_key), :dedupe_key) do
      {:ok,
       %ForemanServer.Events.IntegrationConfigured{
         dedupe_key: dedupe_key,
         config: Aggregate.get(payload, :config)
       }}
    end
  end

  def handle_command(_state, %{type: type, payload: payload})
      when type in ["integration.sync.request", "integration.sync.complete"] do
    with {:ok, dedupe_key} <-
           Aggregate.required_binary(Aggregate.get(payload, :dedupe_key), :dedupe_key) do
      event =
        if type == "integration.sync.request" do
          %ForemanServer.Events.IntegrationSyncRequested{dedupe_key: dedupe_key}
        else
          %ForemanServer.Events.IntegrationSyncCompleted{dedupe_key: dedupe_key}
        end

      {:ok, event}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp require_new(%State{seen?: true}, dedupe_key),
    do: {:error, {:duplicate_integration_event, dedupe_key}}

  defp require_new(_state, _dedupe_key), do: :ok
end
