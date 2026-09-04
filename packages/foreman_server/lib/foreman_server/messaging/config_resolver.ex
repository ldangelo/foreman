defmodule ForemanServer.Messaging.ConfigResolver do
  @moduledoc "Resolves workflow/project/application messaging config with deterministic precedence."

  alias ForemanServer.Messaging.Config

  @providers [:telegram, :slack]
  @event_classes [:collab_url, :action_needed, :stall, :failure, :run_update, :test]
  @defaults %{
    enabled: false,
    provider: :telegram,
    event_classes: [:collab_url, :action_needed, :stall, :failure],
    dedupe_window_ms: 300_000,
    run_update_rate_limit_ms: 300_000,
    telegram: %{},
    slack: %{}
  }

  @spec resolve(keyword()) :: {:ok, Config.t()} | {:error, term()}
  def resolve(opts \\ []) when is_list(opts) do
    app = Application.get_env(:foreman_server, :messaging, []) |> normalize_map()
    project = opts |> Keyword.get(:project_config, %{}) |> messaging_section()
    workflow = opts |> Keyword.get(:workflow_config, %{}) |> messaging_section()
    raw = @defaults |> Map.merge(app) |> Map.merge(project) |> Map.merge(workflow)

    enabled? = truthy?(get(raw, :enabled))

    with {:ok, provider} <- provider(raw),
         {:ok, event_classes} <- event_classes(raw),
         {:ok, destination} <- maybe_destination(raw, provider, enabled?),
         {:ok, dedupe_window_ms} <- non_negative_int(raw, :dedupe_window_ms),
         {:ok, run_update_rate_limit_ms} <- non_negative_int(raw, :run_update_rate_limit_ms) do
      {:ok,
       %Config{
         enabled?: enabled?,
         provider: provider,
         event_classes: event_classes,
         dedupe_window_ms: dedupe_window_ms,
         run_update_rate_limit_ms: run_update_rate_limit_ms,
         destination: destination
       }}
    end
  end

  def enabled_for?(%Config{enabled?: true, event_classes: classes}, event_class),
    do: normalize_atom(event_class) in classes

  def enabled_for?(%Config{}, _event_class), do: false

  defp messaging_section(map) when is_map(map) do
    case get(map, :notifications) || get(map, :messaging) do
      value when is_map(value) -> normalize_map(value)
      _ -> normalize_map(map)
    end
  end

  defp messaging_section(_), do: %{}

  defp provider(raw) do
    case normalize_atom(get(raw, :provider)) do
      provider when provider in @providers -> {:ok, provider}
      value -> {:error, {:unsupported_provider, value}}
    end
  end

  defp event_classes(raw) do
    classes = get(raw, :event_classes, @defaults.event_classes)

    cond do
      is_list(classes) ->
        normalized = Enum.map(classes, &normalize_atom/1)

        if Enum.all?(normalized, &(&1 in @event_classes)),
          do: {:ok, normalized},
          else: {:error, {:missing_or_invalid, :event_classes, classes}}

      true ->
        {:error, {:missing_or_invalid, :event_classes, classes}}
    end
  end

  defp maybe_destination(_raw, _provider, false), do: {:ok, nil}
  defp maybe_destination(raw, provider, true), do: destination(raw, provider)

  defp destination(raw, :telegram) do
    cfg = provider_config(raw, :telegram)
    token = get(cfg, :token)
    chat_id = get(cfg, :chat_id)

    if valid_secret_ref?(token) and is_binary(chat_id) and chat_id != "" do
      {:ok, %{provider: :telegram, token: token, chat_id: chat_id}}
    else
      {:error, {:missing_or_invalid, :telegram_destination}}
    end
  end

  defp destination(raw, :slack) do
    cfg = provider_config(raw, :slack)
    webhook_url = get(cfg, :webhook_url)

    if valid_secret_ref?(webhook_url) do
      {:ok, %{provider: :slack, webhook_url: webhook_url}}
    else
      {:error, {:missing_or_invalid, :slack_destination}}
    end
  end

  defp provider_config(raw, provider) do
    case get(raw, provider, %{}) do
      cfg when is_map(cfg) -> normalize_map(cfg)
      cfg when is_list(cfg) -> Map.new(cfg)
      _ -> %{}
    end
  end

  defp valid_secret_ref?({:system, name}) when is_binary(name) and name != "", do: true
  defp valid_secret_ref?(value) when is_binary(value) and value != "", do: true
  defp valid_secret_ref?(_), do: false

  defp non_negative_int(raw, key) do
    case get(raw, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      value -> {:error, {:missing_or_invalid, key, value}}
    end
  end

  defp truthy?(value), do: value in [true, "true", true, "1", 1]
  defp normalize_map(list) when is_list(list), do: Map.new(list)
  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_), do: %{}

  defp get(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp normalize_atom(value) when is_atom(value), do: value

  defp normalize_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp normalize_atom(value), do: value
end
