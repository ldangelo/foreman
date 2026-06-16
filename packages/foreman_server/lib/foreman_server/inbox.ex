defmodule ForemanServer.Inbox do
  @moduledoc "Event-backed inbox and agent mail boundary."

  alias ForemanServer.{EventStore, ProjectionStore}

  @phase_events %{
    "PhaseStarted" => "phase_started",
    "PhaseCompleted" => "phase_completed",
    "PhaseFailed" => "phase_failed"
  }

  @terminal_statuses MapSet.new(["completed", "failed", "blocked"])

  @spec subscribe(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def subscribe(run_id) when is_binary(run_id) and run_id != "" do
    with :ok <- ensure_registry() do
      Registry.register(ForemanServer.InboxRegistry, run_id, [])
      {:ok, length(list(run_id))}
    end
  end

  @spec list(String.t()) :: [map()]
  def list(run_id) when is_binary(run_id) do
    ProjectionStore.snapshot()
    |> get_in([:inbox_by_run, run_id])
    |> Kernel.||([])
    |> Enum.map(&get_in(ProjectionStore.snapshot(), [:inbox_messages, &1]))
    |> Enum.reject(&is_nil/1)
  end

  @spec append_phase_mail(String.t(), map(), map()) :: {:ok, [map()]} | {:error, term()}
  def append_phase_mail(event_type, payload, hooks)
      when is_binary(event_type) and is_map(payload) do
    payload = atomize_keys(payload)
    hooks = atomize_keys(hooks || %{})

    case hook_config(event_type, hooks) do
      [] -> {:ok, []}
      configs -> append_hook_messages(event_type, payload, configs)
    end
  end

  @spec send_operator_message(map()) :: {:ok, map()} | {:error, term()}
  def send_operator_message(input) when is_map(input) do
    input = atomize_keys(input)

    with {:ok, run_id} <- required_binary(Map.get(input, :run_id), :run_id),
         {:ok, body} <- required_binary(Map.get(input, :body), :body),
         :ok <- active_run(run_id) do
      supports_delivery? = Map.get(input, :worker_supports_receiving, false)
      status = if supports_delivery?, do: "queued", else: "unsupported"

      append_message(%{
        message_id: Map.get(input, :message_id, "msg-#{System.unique_integer([:positive])}"),
        run_id: run_id,
        phase_id: Map.get(input, :phase_id),
        from: Map.get(input, :from, "operator"),
        to: Map.get(input, :to, "worker"),
        body: body,
        direction: "operator_to_worker",
        delivery_status: status,
        delivery: %{supported: supports_delivery?}
      })
    end
  end

  @spec update_delivery(map()) :: {:ok, map()} | {:error, term()}
  def update_delivery(input) when is_map(input) do
    input = atomize_keys(input)

    with {:ok, message_id} <- required_binary(Map.get(input, :message_id), :message_id),
         {:ok, status} <- required_binary(Map.get(input, :delivery_status), :delivery_status),
         {:ok, message} <- existing_message(message_id) do
      append_delivery_update(%{
        message_id: message_id,
        run_id: message.run_id,
        delivery_status: status,
        delivery: Map.get(input, :delivery, %{}),
        reason: Map.get(input, :reason)
      })
    end
  end

  defp append_hook_messages(event_type, payload, configs) do
    results =
      Enum.map(configs, fn config ->
        append_message(%{
          message_id:
            Map.get(
              config,
              :message_id,
              "mail-#{payload.run_id}-#{payload.phase_id}-#{event_type}-#{System.unique_integer([:positive])}"
            ),
          run_id: payload.run_id,
          phase_id: Map.get(payload, :phase_id),
          from: Map.get(config, :from, "foreman"),
          to: Map.get(config, :to, "agent"),
          body: render_body(config, event_type, payload),
          direction: "system_to_agent",
          hook: @phase_events[event_type] || event_type,
          delivery_status: Map.get(config, :delivery_status, "appended")
        })
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, result} -> result end)}
      error -> error
    end
  end

  defp hook_config(event_type, hooks) do
    key = @phase_events[event_type] || event_type
    hooks |> Map.get(String.to_atom(key), Map.get(hooks, key, [])) |> normalize_configs()
  end

  defp normalize_configs(false), do: []
  defp normalize_configs(nil), do: []
  defp normalize_configs(true), do: [%{}]
  defp normalize_configs(config) when is_map(config), do: [config]
  defp normalize_configs(configs) when is_list(configs), do: configs
  defp normalize_configs(_), do: []

  defp render_body(config, event_type, payload) do
    Map.get(config, :body) ||
      "#{event_type} #{payload.run_id}/#{Map.get(payload, :phase_id, "phase")}"
  end

  defp append_message(message) do
    message =
      message
      |> Map.put_new(:created_at, DateTime.utc_now())
      |> Map.put_new(:delivery_status, "appended")

    with {:ok, event} <-
           EventStore.append(%{
             stream_id: "inbox:#{message.run_id}",
             event_type: "InboxMessageAppended",
             payload: message,
             metadata: %{
               correlation_id: message.run_id,
               idempotency_key: "InboxMessageAppended:#{message.message_id}"
             }
           }) do
      {:ok, %{event: event, projection: ProjectionStore.snapshot(), result: message}}
    end
  end

  defp append_delivery_update(update) do
    update = Map.put_new(update, :updated_at, DateTime.utc_now())

    with {:ok, event} <-
           EventStore.append(%{
             stream_id: "inbox:#{update.run_id}",
             event_type: "InboxDeliveryUpdated",
             payload: update,
             metadata: %{
               correlation_id: update.run_id,
               idempotency_key:
                 "InboxDeliveryUpdated:#{update.message_id}:#{update.delivery_status}:#{System.unique_integer([:positive])}"
             }
           }) do
      {:ok, %{event: event, projection: ProjectionStore.snapshot(), result: update}}
    end
  end

  defp active_run(run_id) do
    run = get_in(ProjectionStore.snapshot(), [:runs, run_id])

    cond do
      is_nil(run) ->
        {:error, {:run_not_found, run_id}}

      MapSet.member?(@terminal_statuses, Map.get(run, :status)) ->
        {:error, {:run_not_active, run_id}}

      true ->
        :ok
    end
  end

  defp existing_message(message_id) do
    case get_in(ProjectionStore.snapshot(), [:inbox_messages, message_id]) do
      nil -> {:error, {:message_not_found, message_id}}
      message -> {:ok, message}
    end
  end

  defp ensure_registry do
    case Process.whereis(ForemanServer.InboxRegistry) do
      nil -> {:error, :inbox_registry_not_started}
      _pid -> :ok
    end
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
