defmodule ForemanServer.Inbox do
  @moduledoc "Event-backed inbox and agent mail boundary."

  alias ForemanServer.{EventStore, ProjectionStore}

  @phase_events %{
    "PhaseStarted" => "phase_started",
    "PhaseCompleted" => "phase_completed",
    "PhaseFailed" => "phase_failed"
  }

  @hook_aliases %{
    "phase_started" => [:phase_started, :on_start, "phase_started", "on_start", "onStart"],
    "phase_completed" => [
      :phase_completed,
      :on_complete,
      "phase_completed",
      "on_complete",
      "onComplete"
    ],
    "phase_failed" => [:phase_failed, :on_fail, "phase_failed", "on_fail", "onFail"]
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
    snapshot = ProjectionStore.snapshot()

    snapshot
    |> get_in([:inbox_by_run, run_id])
    |> Kernel.||([])
    |> Enum.map(&get_in(snapshot, [:inbox_messages, &1]))
    |> Enum.reject(&is_nil/1)
  end

  @spec append_phase_mail(String.t(), map(), map()) :: {:ok, [map()]} | {:error, term()}
  def append_phase_mail(event_type, payload, hooks)
      when is_binary(event_type) and is_map(payload) do
    case hook_config(event_type, hooks || %{}) do
      [] -> {:ok, []}
      configs -> append_hook_messages(event_type, payload, configs)
    end
  end

  @spec send_operator_message(map()) :: {:ok, map()} | {:error, term()}
  def send_operator_message(input) when is_map(input) do
    with {:ok, run_id} <- required_binary(fetch(input, :run_id), :run_id),
         {:ok, body} <- required_binary(fetch(input, :body), :body),
         :ok <- active_run(run_id) do
      supports_delivery? = fetch(input, :worker_supports_receiving, false)
      status = if supports_delivery?, do: "queued", else: "unsupported"

      append_message(%{
        message_id: fetch(input, :message_id, "msg-#{System.unique_integer([:positive])}"),
        run_id: run_id,
        phase_id: fetch(input, :phase_id),
        from: fetch(input, :from, "operator"),
        to: fetch(input, :to, "worker"),
        body: body,
        direction: "operator_to_worker",
        delivery_status: status,
        delivery: %{supported: supports_delivery?}
      })
    end
  end

  @spec update_delivery(map()) :: {:ok, map()} | {:error, term()}
  def update_delivery(input) when is_map(input) do
    with {:ok, message_id} <- required_binary(fetch(input, :message_id), :message_id),
         {:ok, status} <- required_binary(fetch(input, :delivery_status), :delivery_status),
         {:ok, message} <- existing_message(message_id) do
      append_delivery_update(%{
        message_id: message_id,
        run_id: message.run_id,
        delivery_status: status,
        delivery: fetch(input, :delivery, %{}),
        reason: fetch(input, :reason)
      })
    end
  end

  defp append_hook_messages(event_type, payload, configs) do
    with {:ok, run_id} <- required_binary(fetch(payload, :run_id), :run_id),
         {:ok, phase_id} <- required_binary(fetch(payload, :phase_id), :phase_id),
         {:ok, messages} <- build_hook_messages(event_type, payload, configs, run_id, phase_id) do
      append_messages(messages, [])
    end
  end

  defp build_hook_messages(event_type, payload, configs, run_id, phase_id) do
    messages =
      Enum.map(configs, fn config ->
        %{
          message_id:
            fetch(
              config,
              :message_id,
              "mail-#{run_id}-#{phase_id}-#{event_type}-#{System.unique_integer([:positive])}"
            ),
          run_id: run_id,
          phase_id: phase_id,
          from: fetch(config, :from, "foreman"),
          to: fetch(config, :to, "agent"),
          body: render_body(config, event_type, payload),
          direction: "system_to_agent",
          hook: @phase_events[event_type] || event_type,
          delivery_status: fetch(config, :delivery_status, "appended")
        }
      end)

    cond do
      Enum.any?(messages, &(not is_binary(&1.message_id) or &1.message_id == "")) ->
        {:error, {:missing_or_invalid, :message_id}}

      duplicate_ids?(messages) ->
        {:error, :duplicate_message_id}

      true ->
        {:ok, messages}
    end
  end

  defp append_messages([], acc), do: {:ok, Enum.reverse(acc)}

  defp append_messages([message | rest], acc) do
    case append_message(message) do
      {:ok, result} -> append_messages(rest, [result | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  defp duplicate_ids?(messages) do
    ids = Enum.map(messages, & &1.message_id)
    length(ids) != length(Enum.uniq(ids))
  end

  defp hook_config(event_type, hooks) do
    key = @phase_events[event_type] || event_type

    key
    |> hook_keys()
    |> Enum.find_value([], fn hook_key ->
      case fetch_hook(hooks, hook_key) do
        nil -> nil
        value -> value
      end
    end)
    |> normalize_configs()
  end

  defp hook_keys(key), do: Map.get(@hook_aliases, key, [key])

  defp fetch_hook(hooks, key) when is_map(hooks), do: Map.get(hooks, key)
  defp fetch_hook(_hooks, _key), do: nil

  defp normalize_configs(false), do: []
  defp normalize_configs(nil), do: []
  defp normalize_configs(true), do: [%{}]
  defp normalize_configs(recipient) when is_binary(recipient), do: [%{to: recipient}]
  defp normalize_configs(config) when is_map(config), do: [config]
  defp normalize_configs(configs) when is_list(configs), do: configs
  defp normalize_configs(_), do: []

  defp render_body(config, event_type, payload) do
    fetch(config, :body) ||
      "#{event_type} #{fetch(payload, :run_id)}/#{fetch(payload, :phase_id, "phase")}"
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

  defp fetch(map, key, default \\ nil)

  defp fetch(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp fetch(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp fetch(_value, _key, default), do: default
end
