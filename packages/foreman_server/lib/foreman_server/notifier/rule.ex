defmodule ForemanServer.Notifier.Rule do
  @moduledoc """
  One row of the `ForemanServer.Notifier.Mapping` table: how a projected event
  becomes a `ForemanServer.Messaging` notification.

    * `event_type` - projection event type, e.g. `"RunFailed"`.
    * `match` - optional `%{field => [allowed string values]}`; the rule applies
      only when every listed payload field (compared as a string) is one of the
      allowed values. Lets one event type map to different classes by content.
    * `class` - a `Messaging.Notification` event class.
    * `severity` - a `Messaging.Notification` severity.
    * `level` - `:blocked` (the thread needs you / something broke) or
      `:progress` (good news and routine updates). A project's
      `notification_preference` decides which levels are delivered.
    * `subject` - fixed notification subject.
    * `body_fields` - payload fields rendered as `field: value` lines of the body.
    * `key_fields` - payload fields identifying ONE occurrence; they form the
      deduplication key, so they must differ between genuinely different events
      and be equal for a replay of the same one.
    * `url_field` - optional payload field holding a link (a PR url).
  """

  @classes [:collab_url, :action_needed, :stall, :failure, :run_update, :test]
  @severities [:info, :warning, :critical]
  @levels [:blocked, :progress]

  @enforce_keys [:event_type, :class, :severity, :level, :subject, :key_fields]
  defstruct [
    :event_type,
    :class,
    :severity,
    :level,
    :subject,
    :url_field,
    key_fields: [],
    body_fields: [],
    match: %{}
  ]

  @type level :: :blocked | :progress

  @type t :: %__MODULE__{
          event_type: String.t(),
          match: %{optional(String.t()) => [String.t()]},
          class: atom(),
          severity: :info | :warning | :critical,
          level: level(),
          subject: String.t(),
          body_fields: [String.t()],
          key_fields: [String.t()],
          url_field: String.t() | nil
        }

  @doc """
  Builds a validated rule from a map or keyword list (atom keys). Field names
  may be atoms or strings. Raises `ArgumentError` on a malformed rule: a bad
  rule is a configuration bug, surfaced when the notifier starts rather than
  as a silently missing notification.
  """
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) when is_list(attrs), do: attrs |> Map.new() |> new!()

  def new!(%{} = attrs) do
    event_type = fetch!(attrs, :event_type)
    class = fetch!(attrs, :class)
    severity = Map.get(attrs, :severity, :info)
    level = fetch!(attrs, :level)
    subject = fetch!(attrs, :subject)

    validate!(is_binary(event_type) and event_type != "", :event_type, event_type)
    validate!(class in @classes, :class, class)
    validate!(severity in @severities, :severity, severity)
    validate!(level in @levels, :level, level)
    validate!(is_binary(subject) and subject != "", :subject, subject)

    %__MODULE__{
      event_type: event_type,
      class: class,
      severity: severity,
      level: level,
      subject: subject,
      match: normalize_match!(Map.get(attrs, :match, %{})),
      body_fields: names!(Map.get(attrs, :body_fields, []), :body_fields),
      key_fields: names!(fetch!(attrs, :key_fields), :key_fields),
      url_field: optional_name!(Map.get(attrs, :url_field), :url_field)
    }
  end

  @doc "Does the rule apply to a payload with string or atom keys?"
  @spec matches?(t(), map()) :: boolean()
  def matches?(%__MODULE__{match: match}, payload) do
    Enum.all?(match, fn {field, allowed} ->
      case field_value(payload, field) do
        nil -> false
        value -> to_string(value) in allowed
      end
    end)
  end

  @doc """
  Reads `field` (a string) from a payload that may carry atom or string keys.
  A payload holding both forms with different values is corrupt and raises.
  """
  @spec field_value(map(), String.t()) :: term()
  def field_value(payload, field) when is_map(payload) and is_binary(field) do
    atom_entry =
      Enum.find(payload, fn {key, _} -> is_atom(key) and Atom.to_string(key) == field end)

    case {atom_entry, Map.fetch(payload, field)} do
      {{_key, value}, :error} ->
        value

      {nil, {:ok, value}} ->
        value

      {nil, :error} ->
        nil

      {{_key, value}, {:ok, value}} ->
        value

      {{_key, a}, {:ok, s}} ->
        raise ArgumentError, "conflicting #{field} keys: #{inspect(a)} vs #{inspect(s)}"
    end
  end

  defp fetch!(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "notifier rule is missing #{inspect(key)}: #{inspect(attrs)}"
    end
  end

  defp validate!(true, _key, _value), do: :ok

  defp validate!(false, key, value),
    do: raise(ArgumentError, "notifier rule has invalid #{inspect(key)}: #{inspect(value)}")

  defp normalize_match!(match) when is_map(match) do
    Map.new(match, fn {field, allowed} ->
      validate!(is_list(allowed) and allowed != [], :match, {field, allowed})
      {name!(field, :match), Enum.map(allowed, &to_string/1)}
    end)
  end

  defp normalize_match!(other), do: validate!(false, :match, other)

  defp names!(list, key) when is_list(list), do: Enum.map(list, &name!(&1, key))
  defp names!(other, key), do: validate!(false, key, other)

  defp optional_name!(nil, _key), do: nil
  defp optional_name!(name, key), do: name!(name, key)

  defp name!(name, _key) when is_atom(name) and not is_nil(name), do: Atom.to_string(name)
  defp name!(name, _key) when is_binary(name) and name != "", do: name
  defp name!(name, key), do: validate!(false, key, name)
end
