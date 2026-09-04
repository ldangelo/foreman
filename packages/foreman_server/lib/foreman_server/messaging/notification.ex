defmodule ForemanServer.Messaging.Notification do
  @moduledoc "Provider-neutral outbound notification DTO and boundary validation."

  @enforce_keys [:notification_id, :provider, :recipient, :event_class, :severity, :subject, :body, :correlation_id]
  @derive Jason.Encoder
  defstruct [
    :notification_id,
    :provider,
    :recipient,
    :event_class,
    :severity,
    :subject,
    :body,
    :url,
    :correlation_id,
    :run_id,
    metadata: %{}
  ]

  @type t :: %__MODULE__{}

  @allowed_keys MapSet.new(~w(notification_id provider recipient event_class severity subject body url correlation_id run_id metadata)a)
  @required_keys [:provider, :recipient, :event_class, :severity, :subject, :body, :correlation_id]
  @providers [:telegram, :slack]
  @event_classes [:collab_url, :action_needed, :stall, :failure, :run_update, :test]
  @severities [:info, :warning, :critical]
  @safe_metadata_keys MapSet.new(~w(run_id task_id phase_id workflow_name project_id status reason dedupe_key)a)

  @spec normalize(map()) :: {:ok, t()} | {:error, term()}
  def normalize(attrs) when is_map(attrs) do
    with :ok <- reject_unknown_keys(attrs),
         {:ok, provider} <- enum_field(attrs, :provider, @providers),
         {:ok, event_class} <- enum_field(attrs, :event_class, @event_classes),
         {:ok, severity} <- enum_field(attrs, :severity, @severities),
         {:ok, recipient} <- binary_field(attrs, :recipient),
         {:ok, subject} <- binary_field(attrs, :subject),
         {:ok, body} <- binary_field(attrs, :body),
         {:ok, correlation_id} <- binary_field(attrs, :correlation_id),
         :ok <- optional_binary_field(attrs, :url),
         :ok <- optional_binary_field(attrs, :run_id),
         {:ok, metadata} <- metadata_field(attrs),
         {:ok, notification_id} <- notification_id(attrs, provider, correlation_id) do
      {:ok,
       %__MODULE__{
         notification_id: notification_id,
         provider: provider,
         recipient: recipient,
         event_class: event_class,
         severity: severity,
         subject: subject,
         body: body,
         url: get(attrs, :url),
         correlation_id: correlation_id,
         run_id: get(attrs, :run_id),
         metadata: metadata
       }}
    end
  end

  def normalize(value), do: {:error, {:missing_or_invalid, :notification, value}}

  @spec to_event_payload(t()) :: map()
  def to_event_payload(%__MODULE__{} = notification), do: Map.from_struct(notification)

  defp notification_id(attrs, provider, correlation_id) do
    case get(attrs, :notification_id) do
      nil -> {:ok, "#{provider}:#{correlation_id}"}
      value when is_binary(value) and value != "" -> {:ok, value}
      value -> {:error, {:missing_or_invalid, :notification_id, value}}
    end
  end

  defp reject_unknown_keys(attrs) do
    unknown =
      attrs
      |> Map.keys()
      |> Enum.map(&normalize_key/1)
      |> Enum.reject(&MapSet.member?(@allowed_keys, &1))

    case unknown do
      [] -> :ok
      keys -> {:error, {:unknown_keys, Enum.sort(keys)}}
    end
  end

  defp enum_field(attrs, key, allowed) do
    case normalize_atom(get(attrs, key)) do
      atom when atom in allowed -> {:ok, atom}
      value -> {:error, {:missing_or_invalid, key, value}}
    end
  end

  defp binary_field(attrs, key) do
    case get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value -> {:error, {:missing_or_invalid, key, value}}
    end
  end

  defp optional_binary_field(attrs, key) do
    case get(attrs, key) do
      nil -> :ok
      value when is_binary(value) and value != "" -> :ok
      value -> {:error, {:missing_or_invalid, key, value}}
    end
  end

  defp metadata_field(attrs) do
    case get(attrs, :metadata, %{}) do
      metadata when is_map(metadata) ->
        {:ok,
         Enum.reduce(metadata, %{}, fn {key, value}, acc ->
           atom_key = normalize_key(key)

           if MapSet.member?(@safe_metadata_keys, atom_key), do: Map.put(acc, atom_key, value), else: acc
         end)}

      value ->
        {:error, {:missing_or_invalid, :metadata, value}}
    end
  end

  defp get(map, key, default \\ nil), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  defp normalize_atom(value) when is_atom(value), do: value
  defp normalize_atom(value) when is_binary(value), do: String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end
  defp normalize_atom(value), do: value
  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: String.to_existing_atom(key)
  rescue
    ArgumentError -> String.to_atom(key)
  end
end
