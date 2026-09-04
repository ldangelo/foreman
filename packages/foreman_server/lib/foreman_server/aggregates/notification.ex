defmodule ForemanServer.Aggregates.Notification do
  @moduledoc "Notification aggregate: validates enqueue/suppression/delivery lifecycle."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate
  alias ForemanServer.Messaging.Notification, as: NotificationDto

  defmodule State do
    @enforce_keys [:exists?]
    defstruct [:exists?, :notification_id, :correlation_id, :provider, :run_id, :status, :last_sequence, :last_enqueued_at_ms, attempts: %{}]
  end

  @impl true
  def initial_state,
    do: %State{exists?: false, attempts: %{}, last_sequence: 0}

  @impl true
  def apply_event(%State{} = state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "NotificationEnqueued" ->
        %State{state | exists?: true, notification_id: get(payload, :notification_id), correlation_id: get(payload, :correlation_id), provider: get(payload, :provider), run_id: get(payload, :run_id) || state.run_id, status: :enqueued, last_sequence: get(payload, :sequence, state.last_sequence), last_enqueued_at_ms: get(payload, :enqueued_at_ms) || get(payload, :event_at_ms) || state.last_enqueued_at_ms}

      "NotificationSuppressed" ->
        %State{state | exists?: true, notification_id: get(payload, :notification_id), correlation_id: get(payload, :correlation_id), provider: get(payload, :provider), run_id: get(payload, :run_id) || state.run_id, status: :suppressed, last_sequence: get(payload, :sequence, state.last_sequence)}

      "NotificationDeliveryAttempted" ->
        put_attempt(state, payload, :attempted)

      "NotificationDeliverySucceeded" ->
        put_attempt(%State{state | status: :succeeded}, payload, :succeeded)

      "NotificationDeliveryFailed" ->
        put_attempt(%State{state | status: :failed}, payload, :failed)

      _ ->
        state
    end
  end

  @impl true
  def handle_command(state, %{type: "notification.enqueue", payload: payload}) do
    with {:ok, dto} <- NotificationDto.normalize(payload),
         {:ok, now_ms} <- non_negative_int(get(payload, :now_ms), :now_ms),
         {:ok, dedupe_window_ms} <- non_negative_int(get(payload, :dedupe_window_ms, 300_000), :dedupe_window_ms) do
      cond do
        duplicate?(state, dto.correlation_id, now_ms, dedupe_window_ms) ->
          suppressed(dto, payload, "duplicate")

        get(payload, :enabled, true) in [false, "false"] ->
          suppressed(dto, payload, "disabled")

        true ->
          {:ok,
           %{
             stream_id: stream_id(dto.correlation_id),
             event_type: "NotificationEnqueued",
             payload: dto |> NotificationDto.to_event_payload() |> Map.put(:sequence, next_sequence(state)) |> Map.put(:enqueued_at_ms, now_ms)
           }}
      end
    end
  end

  def handle_command(state, %{type: "notification.delivery_attempt", payload: payload}) do
    with {:ok, notification_id} <- required_binary(get(payload, :notification_id), :notification_id),
         {:ok, attempt_id} <- required_binary(get(payload, :attempt_id), :attempt_id),
         {:ok, provider} <- required_binary(to_string_value(get(payload, :provider)), :provider),
         {:ok, correlation_id} <- required_binary(get(payload, :correlation_id) || state.correlation_id, :correlation_id) do
      {:ok, %{stream_id: stream_id(correlation_id), event_type: "NotificationDeliveryAttempted", payload: Map.merge(payload, %{notification_id: notification_id, attempt_id: attempt_id, provider: provider, correlation_id: correlation_id, sequence: next_sequence(state)})}}
    end
  end

  def handle_command(state, %{type: "notification.delivery_success", payload: payload}) do
    result_event(state, payload, "NotificationDeliverySucceeded", [:delivered_at])
  end

  def handle_command(state, %{type: "notification.delivery_failure", payload: payload}) do
    result_event(state, payload, "NotificationDeliveryFailed", [:reason, :retryable?])
  end

  def handle_command(_state, _command), do: :unhandled

  defp duplicate?(%State{correlation_id: correlation_id, last_enqueued_at_ms: last}, correlation_id, now_ms, window) when is_integer(last), do: now_ms - last < window
  defp duplicate?(_, _, _, _), do: false

  defp suppressed(dto, payload, reason) do
    {:ok, %{stream_id: stream_id(dto.correlation_id), event_type: "NotificationSuppressed", payload: %{notification_id: dto.notification_id, provider: dto.provider, event_class: dto.event_class, correlation_id: dto.correlation_id, run_id: dto.run_id, reason: reason, sequence: get(payload, :sequence, 0), metadata: dto.metadata}}}
  end

  defp result_event(state, payload, event_type, required_keys) do
    with {:ok, notification_id} <- required_binary(get(payload, :notification_id) || state.notification_id, :notification_id),
         {:ok, attempt_id} <- required_binary(get(payload, :attempt_id), :attempt_id),
         {:ok, provider} <- required_binary(to_string_value(get(payload, :provider) || state.provider), :provider),
         {:ok, correlation_id} <- required_binary(get(payload, :correlation_id) || state.correlation_id, :correlation_id),
         :ok <- require_keys(payload, required_keys) do
      {:ok, %{stream_id: stream_id(correlation_id), event_type: event_type, payload: Map.merge(payload, %{notification_id: notification_id, attempt_id: attempt_id, provider: provider, correlation_id: correlation_id, run_id: get(payload, :run_id) || state.run_id, sequence: next_sequence(state)})}}
    end
  end

  defp require_keys(payload, keys) do
    case Enum.find(keys, &(is_nil(get(payload, &1)))) do
      nil -> :ok
      key -> {:error, {:missing_or_invalid, key}}
    end
  end

  defp put_attempt(state, payload, status) do
    attempt_id = get(payload, :attempt_id)
    attempt = %{attempt_id: attempt_id, status: status, reason: get(payload, :reason), retryable?: get(payload, :retryable?), metadata: get(payload, :metadata, %{})}
    %State{state | exists?: true, notification_id: get(payload, :notification_id) || state.notification_id, correlation_id: get(payload, :correlation_id) || state.correlation_id, provider: get(payload, :provider) || state.provider, run_id: get(payload, :run_id) || state.run_id, status: status, last_sequence: get(payload, :sequence, state.last_sequence), attempts: Map.put(state.attempts, attempt_id, attempt)}
  end

  defp next_sequence(%State{last_sequence: n}) when is_integer(n), do: n + 1
  defp stream_id(correlation_id), do: "notification:" <> correlation_id
  defp get(map, key, default \\ nil), do: Aggregate.get(map, key, default)
  defp required_binary(value, key), do: Aggregate.required_binary(value, key)
  defp non_negative_int(value, key) when is_integer(value) and value >= 0, do: {:ok, value}
  defp non_negative_int(nil, :now_ms), do: {:ok, System.system_time(:millisecond)}
  defp non_negative_int(value, key), do: {:error, {:missing_or_invalid, key, value}}
  defp to_string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp to_string_value(value), do: value
end
