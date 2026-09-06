defmodule ForemanServer.Messaging.Dispatcher do
  @moduledoc """
  Supervised durable outbound notification dispatcher.

  Delivery is intentionally outside `ForemanServer.Messaging.notify/2`: notify only
  persists enqueue/suppression events, while this process catches up from the event
  log and reacts to projection broadcasts. A notification is sent at most once after
  any delivery attempt event exists for its notification id.
  """

  use GenServer
  require Logger

  alias EventStore.{EventData, RecordedEvent}

  alias ForemanServer.{
    CommandRouter,
    Messaging.ConfigResolver,
    Messaging.Notification,
    Messaging.Redactor
  }

  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.Messaging.DeliveryResult

  @event_page_size 99_999_999

  defstruct command_router: CommandRouter,
            event_store: Store,
            projection_store: ForemanServer.ProjectionStore,
            provider_modules: %{},
            delivering: MapSet.new(),
            subscribe?: true,
            catch_up?: true

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      command_router: Keyword.get(opts, :command_router, CommandRouter),
      event_store: Keyword.get(opts, :event_store, Store),
      projection_store: Keyword.get(opts, :projection_store, ForemanServer.ProjectionStore),
      provider_modules: provider_modules(opts),
      subscribe?: Keyword.get(opts, :subscribe?, true),
      catch_up?: Keyword.get(opts, :catch_up?, true)
    }

    if state.subscribe?, do: safe_subscribe(state.projection_store)
    if state.catch_up?, do: send(self(), :catch_up)

    {:ok, state}
  end

  @impl true
  def handle_info(:catch_up, state) do
    state =
      state.event_store.read_all_streams_forward(0, @event_page_size)
      |> case do
        {:ok, events} ->
          events
          |> pending_notifications()
          |> Enum.reduce(state, &deliver/2)

        {:error, reason} ->
          Logger.warning("messaging dispatcher catch-up failed: #{inspect(reason)}")
          state
      end

    {:noreply, state}
  end

  def handle_info({:projection_event, event}, state) do
    state =
      case event_to_notification(event) do
        {:ok, notification} -> deliver(notification, state)
        :ignore -> state
      end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  def pending_notifications(events) when is_list(events) do
    {enqueued, attempted} =
      Enum.reduce(events, {%{}, MapSet.new()}, fn event, {enqueued, attempted} ->
        case event_type_and_payload(event) do
          {"NotificationEnqueued", payload} ->
            case Notification.normalize(payload) do
              {:ok, notification} ->
                {Map.put(enqueued, notification.notification_id, notification), attempted}

              {:error, _reason} ->
                {enqueued, attempted}
            end

          {type, payload}
          when type in [
                 "NotificationDeliveryAttempted",
                 "NotificationDeliverySucceeded",
                 "NotificationDeliveryFailed"
               ] ->
            notification_id = get(payload, :notification_id)

            if is_binary(notification_id) and notification_id != "" do
              {enqueued, MapSet.put(attempted, notification_id)}
            else
              {enqueued, attempted}
            end

          _ ->
            {enqueued, attempted}
        end
      end)

    enqueued
    |> Map.reject(fn {notification_id, _notification} ->
      MapSet.member?(attempted, notification_id)
    end)
    |> Map.values()
  end

  defp deliver(%Notification{notification_id: notification_id} = notification, state) do
    if MapSet.member?(state.delivering, notification_id) do
      state
    else
      state = %{state | delivering: MapSet.put(state.delivering, notification_id)}
      _ = do_deliver(notification, state)
      %{state | delivering: MapSet.delete(state.delivering, notification_id)}
    end
  end

  defp do_deliver(%Notification{} = notification, state) do
    attempt_id = attempt_id(notification)

    with :ok <- dispatch_attempt(state.command_router, notification, attempt_id),
         {:ok, provider} <- provider_module(state.provider_modules, notification.provider),
         {:ok, destination} <- destination(notification) do
      case provider.send(notification, destination) do
        {:ok, %DeliveryResult{} = result} ->
          dispatch_success(state.command_router, notification, attempt_id, result)

        {:error, %DeliveryResult{} = result} ->
          dispatch_failure(state.command_router, notification, attempt_id, result)
      end
    else
      {:error, reason} ->
        dispatch_failure(state.command_router, notification, attempt_id, %DeliveryResult{
          notification_id: notification.notification_id,
          provider: notification.provider,
          status: :failed,
          retryable?: false,
          reason: inspect(reason)
        })
    end
  end

  defp dispatch_attempt(router, notification, attempt_id) do
    router.dispatch(%{
      aggregate_id: "notification:#{notification.correlation_id}",
      type: "notification.delivery_attempt",
      payload: %{
        notification_id: notification.notification_id,
        attempt_id: attempt_id,
        provider: Atom.to_string(notification.provider),
        correlation_id: notification.correlation_id,
        run_id: notification.run_id,
        metadata: %{event_class: Atom.to_string(notification.event_class)}
      }
    })
    |> ok_or_error()
  end

  defp dispatch_success(router, notification, attempt_id, result) do
    router.dispatch(%{
      aggregate_id: "notification:#{notification.correlation_id}",
      type: "notification.delivery_success",
      payload: %{
        notification_id: notification.notification_id,
        attempt_id: attempt_id,
        provider: Atom.to_string(notification.provider),
        correlation_id: notification.correlation_id,
        run_id: notification.run_id,
        delivered_at: result.delivered_at || DateTime.utc_now() |> DateTime.to_iso8601(),
        metadata: Redactor.redact(result.metadata || %{})
      }
    })
    |> ok_or_error()
  end

  defp dispatch_failure(router, notification, attempt_id, result) do
    router.dispatch(%{
      aggregate_id: "notification:#{notification.correlation_id}",
      type: "notification.delivery_failure",
      payload: %{
        notification_id: notification.notification_id,
        attempt_id: attempt_id,
        provider: Atom.to_string(notification.provider),
        correlation_id: notification.correlation_id,
        run_id: notification.run_id,
        reason: result.reason |> Redactor.redact() |> to_string(),
        retryable?: result.retryable?,
        metadata: Redactor.redact(result.metadata || %{})
      }
    })
    |> ok_or_error()
  end

  defp ok_or_error({:ok, _}), do: :ok
  defp ok_or_error(:ok), do: :ok
  defp ok_or_error({:error, reason}), do: {:error, reason}

  defp event_to_notification(event) do
    case event_type_and_payload(event) do
      {"NotificationEnqueued", payload} ->
        case Notification.normalize(payload) do
          {:ok, notification} -> {:ok, notification}
          {:error, _reason} -> :ignore
        end

      _ ->
        :ignore
    end
  end

  defp event_type_and_payload(%RecordedEvent{} = event) do
    {event.event_type, event.data || %{}}
  end

  defp event_type_and_payload(%EventData{} = event) do
    {event.event_type, event.data || %{}}
  end

  defp event_type_and_payload(%{event_type: type, data: data}), do: {type, data || %{}}
  defp event_type_and_payload(%{event_type: type, payload: payload}), do: {type, payload || %{}}
  defp event_type_and_payload(%{type: type, payload: payload}), do: {type, payload || %{}}

  defp get(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp provider_modules(opts) do
    app = Application.get_env(:foreman_server, :messaging, [])

    defaults = %{
      telegram: ForemanServer.Messaging.Providers.Telegram,
      slack: ForemanServer.Messaging.Providers.Slack
    }

    defaults
    |> Map.merge(Map.new(Keyword.get(app, :providers, [])))
    |> Map.merge(Map.new(Keyword.get(opts, :providers, [])))
  end

  defp provider_module(provider_modules, provider) do
    case Map.fetch(provider_modules, provider) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unsupported_provider, provider}}
    end
  end

  defp destination(%Notification{provider: provider, recipient: recipient}) do
    case ConfigResolver.resolve() do
      {:ok, %{provider: ^provider, destination: destination}} when is_map(destination) ->
        {:ok, Map.put(destination, recipient_key(provider), recipient)}

      {:ok, _config} ->
        {:error, {:missing_or_invalid, provider_destination_error(provider)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recipient_key(:telegram), do: :chat_id
  defp recipient_key(:slack), do: :webhook_url
  defp provider_destination_error(:telegram), do: :telegram_destination
  defp provider_destination_error(:slack), do: :slack_destination

  defp attempt_id(%Notification{notification_id: id}), do: id <> ":attempt-1"

  defp safe_subscribe(projection_store) do
    projection_store.subscribe()
  rescue
    exception ->
      Logger.warning(
        "messaging dispatcher projection subscribe failed: #{Exception.message(exception)}"
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning("messaging dispatcher projection subscribe failed: #{inspect(reason)}")
      :ok
  end
end
