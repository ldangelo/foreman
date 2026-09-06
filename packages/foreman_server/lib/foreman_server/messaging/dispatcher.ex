defmodule ForemanServer.Messaging.Dispatcher do
  @moduledoc """
  Supervised durable outbound notification dispatcher.

  Delivery is intentionally outside `ForemanServer.Messaging.notify/2`: notify only
  persists enqueue/suppression events, while this process catches up from the event
  log and reacts to projection broadcasts. A notification is delivered at most once
  per dispatcher process lifetime: the first delivery attempt (from catch-up or a
  live projection event, whichever reaches it first) claims the notification id for
  the rest of this process's life, closing the catch-up/live-delivery race where a
  notification committed during dispatcher startup could otherwise be picked up by
  both paths (CodeRabbit review). Across a process restart, catch-up re-derives the
  pending set from the event log and only excludes notifications with a durable
  terminal outcome (delivered, or failed non-retryably) — an attempt with no
  recorded outcome, or a retryable failure, is retried (CodeRabbit review).
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
            claimed: MapSet.new(),
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

    # Do not swallow a subscribe failure into a plausible-looking :ok
    # (CodeRabbit review): a dispatcher that "started" without live delivery
    # would silently never deliver a notification enqueued after catch-up
    # completes. Let init crash so the supervisor restarts it and retries
    # subscribing.
    if state.subscribe?, do: state.projection_store.subscribe()
    if state.catch_up?, do: send(self(), :catch_up)

    {:ok, state}
  end

  @impl true
  def handle_info(:catch_up, state) do
    case state.event_store.read_all_streams_forward(0, @event_page_size) do
      {:ok, events} ->
        state =
          events
          |> pending_notifications()
          |> Enum.reduce(state, &deliver/2)

        {:noreply, state}

      {:error, reason} ->
        # A silently-skipped catch-up leaves every notification enqueued
        # before this point stranded with no live delivery to pick it up
        # (CodeRabbit review): crash under supervision instead, so the
        # supervisor restarts this process and catch-up is retried rather
        # than permanently abandoned.
        Logger.error("messaging dispatcher catch-up failed: #{inspect(reason)}")
        exit({:catch_up_failed, reason})
    end
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
    {enqueued, terminal} =
      Enum.reduce(events, {%{}, MapSet.new()}, fn event, {enqueued, terminal} ->
        case event_type_and_payload(event) do
          {"NotificationEnqueued", payload} ->
            case Notification.normalize(payload) do
              {:ok, notification} ->
                {Map.put(enqueued, notification.notification_id, notification), terminal}

              {:error, reason} ->
                # A malformed enqueued event silently vanishing left no trace
                # that a notification was ever lost (CodeRabbit review). This
                # runs on every catch-up, including on boot, so — unlike a
                # one-time boundary check — an unconditional raise here would
                # crash-loop the dispatcher forever on a single bad historical
                # event (the same hazard documented for ProjectionStore.init/1
                # in AGENTS.md); log loudly instead of silently discarding.
                Logger.error(
                  "messaging dispatcher: malformed NotificationEnqueued " <>
                    "payload=#{inspect(Redactor.redact(payload))} " <>
                    "reason=#{inspect(Redactor.redact(reason))}"
                )

                {enqueued, terminal}
            end

          {"NotificationDeliveryAttempted", _payload} ->
            # An attempt alone is not terminal: the dispatching process may
            # have crashed before recording success or failure. Leave the
            # notification pending so catch-up retries it (CodeRabbit review).
            {enqueued, terminal}

          {"NotificationDeliverySucceeded", payload} ->
            {enqueued, mark_terminal(terminal, payload)}

          {"NotificationDeliveryFailed", payload} ->
            if get(payload, :retryable?) do
              # Retryable failure: not terminal, catch-up must retry it
              # (CodeRabbit review) rather than excluding it forever.
              {enqueued, unmark_terminal(terminal, payload)}
            else
              {enqueued, mark_terminal(terminal, payload)}
            end

          _ ->
            {enqueued, terminal}
        end
      end)

    enqueued
    |> Map.reject(fn {notification_id, _notification} ->
      MapSet.member?(terminal, notification_id)
    end)
    |> Map.values()
  end

  defp mark_terminal(terminal, payload) do
    case get(payload, :notification_id) do
      id when is_binary(id) and id != "" -> MapSet.put(terminal, id)
      _ -> terminal
    end
  end

  defp unmark_terminal(terminal, payload) do
    case get(payload, :notification_id) do
      id when is_binary(id) and id != "" -> MapSet.delete(terminal, id)
      _ -> terminal
    end
  end

  defp deliver(%Notification{notification_id: notification_id} = notification, state) do
    if MapSet.member?(state.claimed, notification_id) do
      state
    else
      # Claim before delivering and never release for the life of this
      # process: catch-up and a queued live `:projection_event` for the same
      # notification (committed during dispatcher startup, before catch-up's
      # read completes) would otherwise both call do_deliver/2 and send the
      # notification twice (CodeRabbit review). A process restart clears the
      # claim and re-derives the pending set from the event log, which is
      # where retry after a genuine failure belongs.
      state = %{state | claimed: MapSet.put(state.claimed, notification_id)}
      _ = do_deliver(notification, state)
      state
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
          {:ok, notification} ->
            {:ok, notification}

          {:error, reason} ->
            # Same "fail loudly, don't silently discard" fix as the replay
            # path above, but this event is live (not historical replay), so
            # there is no crash-loop hazard to weigh against — log it loudly.
            Logger.error(
              "messaging dispatcher: malformed live NotificationEnqueued " <>
                "payload=#{inspect(Redactor.redact(payload))} " <>
                "reason=#{inspect(Redactor.redact(reason))}"
            )

            :ignore
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

  # A static suffix would collide across retries: since a retryable failure
  # is now redelivered (see pending_notifications/1), a second attempt with
  # the same attempt_id would overwrite the first in the Notification
  # aggregate's attempts map, losing that attempt's history even though the
  # aggregate itself does not dedupe or reject on attempt_id (CodeRabbit
  # review follow-up). `System.unique_integer/1` is only unique within the
  # current BEAM runtime instance, so a dispatcher restart could reuse an
  # earlier id and collide with a pre-restart attempt in the reconstructed
  # attempts map (CodeRabbit review) — use a UUID, restart-safe by
  # construction, matching this repo's existing convention for durable ids
  # (see RunExecutor.generate_session_id/0, WorkRequest.handle_command/2).
  defp attempt_id(%Notification{notification_id: id}) do
    id <> ":attempt-" <> EventStore.UUID.uuid4()
  end
end
