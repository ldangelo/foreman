defmodule ForemanServer.Messaging.ConfigResolver do
  @moduledoc "Resolves workflow/project/application messaging config with deterministic precedence."

  alias ForemanServer.Messaging.Config

  @providers [:telegram, :slack]
  @event_classes [:collab_url, :action_needed, :stall, :failure, :run_update, :test]
  @known_keys [
    :enabled,
    :provider,
    :event_classes,
    :dedupe_window_ms,
    :run_update_rate_limit_ms,
    :telegram,
    :slack
  ]
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
    app =
      Application.get_env(:foreman_server, :messaging, []) |> normalize_map() |> normalize_layer()

    with {:ok, project} <- opts |> Keyword.get(:project_config, %{}) |> messaging_section(),
         {:ok, workflow} <- opts |> Keyword.get(:workflow_config, %{}) |> messaging_section() do
      raw =
        @defaults
        |> Map.merge(app)
        |> Map.merge(normalize_layer(project))
        |> Map.merge(normalize_layer(workflow))

      with {:ok, enabled?} <- parse_enabled(raw),
           {:ok, provider} <- provider(raw),
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
  end

  def enabled_for?(%Config{enabled?: true, event_classes: classes}, event_class),
    do: normalize_atom(event_class) in classes

  def enabled_for?(%Config{}, _event_class), do: false

  defp parse_enabled(raw) do
    case get(raw, :enabled) do
      value when is_boolean(value) -> {:ok, value}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      value -> {:error, {:missing_or_invalid, :enabled, value}}
    end
  end

  # Whitelist and atomize known top-level keys once per layer, so a
  # string-keyed override (the normal shape for project/workflow config
  # loaded from YAML or JSON) is not silently discarded by `@defaults`
  # always supplying the atom key.
  defp normalize_layer(map) when is_map(map) do
    Enum.reduce(@known_keys, %{}, fn key, acc ->
      case Map.fetch(map, key) do
        {:ok, value} ->
          Map.put(acc, key, value)

        :error ->
          case Map.fetch(map, Atom.to_string(key)) do
            {:ok, value} -> Map.put(acc, key, value)
            :error -> acc
          end
      end
    end)
  end

  defp messaging_section(map) when is_map(map) do
    case get(map, :notifications) || get(map, :messaging) do
      nil -> {:ok, normalize_map(map)}
      value when is_map(value) -> {:ok, normalize_map(value)}
      value -> {:error, {:missing_or_invalid, :messaging_section, value}}
    end
  end

  defp messaging_section(_), do: {:ok, %{}}

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

    with {:ok, token} <- required_secret_ref(cfg, :token, :telegram_destination),
         {:ok, chat_id} <- required_string(cfg, :chat_id, :telegram_destination) do
      {:ok, %{provider: :telegram, token: token, chat_id: chat_id}}
    end
  end

  defp destination(raw, :slack) do
    cfg = provider_config(raw, :slack)

    with {:ok, webhook_url} <- required_secret_ref(cfg, :webhook_url, :slack_destination) do
      {:ok, %{provider: :slack, webhook_url: webhook_url}}
    end
  end

  # Distinguishes an absent destination field from one present but invalid
  # (AGENTS.md "Outbound messaging delivery notes"; CodeRabbit review),
  # matching the `:missing_field` / `:invalid_field` convention already used
  # by the Telegram/Slack send adapters instead of the generic
  # `:missing_or_invalid` tag.
  defp required_secret_ref(map, key, error_key) do
    case fetch_field(map, key) do
      :absent ->
        {:error, {:missing_field, error_key, key}}

      {:present, value} ->
        if valid_secret_ref?(value),
          do: {:ok, value},
          else: {:error, {:invalid_field, error_key, key, value}}
    end
  end

  defp required_string(map, key, error_key) do
    case fetch_field(map, key) do
      :absent -> {:error, {:missing_field, error_key, key}}
      {:present, value} when is_binary(value) and value != "" -> {:ok, value}
      {:present, value} -> {:error, {:invalid_field, error_key, key, value}}
    end
  end

  defp fetch_field(map, key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> {:present, Map.get(map, key)}
      Map.has_key?(map, string_key) -> {:present, Map.get(map, string_key)}
      true -> :absent
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

  defp normalize_map(list) when is_list(list), do: Map.new(list)
  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_), do: %{}

  # Same fix as Dispatcher.get/3 (AGENTS.md 5.4): normalize to a single
  # lookup instead of silently preferring the atom form when a map
  # legitimately carries both key representations with different values.
  defp get(map, key, default \\ nil) do
    string_key = Atom.to_string(key)

    case {Map.fetch(map, key), Map.fetch(map, string_key)} do
      {{:ok, value}, :error} ->
        value

      {:error, {:ok, value}} ->
        value

      {:error, :error} ->
        default

      {{:ok, value}, {:ok, value}} ->
        value

      {{:ok, atom_value}, {:ok, string_value}} ->
        raise ArgumentError,
              "conflicting atom/string keys for #{inspect(key)}: " <>
                "#{inspect(atom_value)} vs #{inspect(string_value)}"
    end
  end

  defp normalize_atom(value) when is_atom(value), do: value

  defp normalize_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp normalize_atom(value), do: value
end
