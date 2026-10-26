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
      and be equal for a replay of the same one. At least one is required: with
      none, every event of the type would share one dedupe key.
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
      key_fields: non_empty_names!(fetch!(attrs, :key_fields), :key_fields),
      url_field: optional_name!(Map.get(attrs, :url_field), :url_field)
    }
  end

  @doc """
  Does the rule apply to a payload? `payload` is a normalised one
  (`normalize_payload!/1`).
  """
  @spec matches?(t(), %{optional(String.t()) => term()}) :: boolean()
  def matches?(%__MODULE__{match: match}, payload) do
    Enum.all?(match, fn {field, allowed} ->
      case field_value(payload, field) do
        nil -> false
        value -> to_string(value) in allowed
      end
    end)
  end

  @doc """
  The event payload with every key a string: the ONE key convention the notifier
  reads (AGENTS.md 5.4), applied once where a MAPPED event enters
  `ForemanServer.Notifier.process/3`. Events carry atom keys when freshly
  appended and string keys when they came from JSON, and one payload can hold
  both forms of a key (the crash-loop detector's `run.block` stores `"run_id"`
  and the aggregate adds `:run_id`): equal values collapse into one entry, a
  conflicting pair is a corrupt payload and raises. The message names the key
  only, because the values may be secrets. A typed event struct (the `data` of
  a freshly appended typed event) is read through its fields. Never mints an
  atom; a key that is neither an atom nor a binary raises.
  """
  @spec normalize_payload!(map()) :: %{optional(String.t()) => term()}
  def normalize_payload!(%{__struct__: _} = event),
    do: event |> Map.from_struct() |> normalize_payload!()

  def normalize_payload!(payload) when is_map(payload) do
    Enum.reduce(payload, %{}, fn {key, value}, normalised ->
      name = key_name!(key)

      case Map.fetch(normalised, name) do
        :error ->
          Map.put(normalised, name, value)

        {:ok, ^value} ->
          normalised

        {:ok, _other} ->
          raise ArgumentError, "conflicting #{name} keys in an event payload"
      end
    end)
  end

  defp key_name!(key) when is_atom(key), do: Atom.to_string(key)
  defp key_name!(key) when is_binary(key), do: key

  @doc "Reads `field` from a normalised payload (`normalize_payload!/1`); `nil` when absent."
  @spec field_value(%{optional(String.t()) => term()}, String.t()) :: term()
  def field_value(payload, field) when is_map(payload) and is_binary(field),
    do: Map.get(payload, field)

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

  defp non_empty_names!(list, key) when is_list(list) and list != [], do: names!(list, key)
  defp non_empty_names!(other, key), do: validate!(false, key, other)

  defp optional_name!(nil, _key), do: nil
  defp optional_name!(name, key), do: name!(name, key)

  defp name!(name, _key) when is_atom(name) and not is_nil(name), do: Atom.to_string(name)
  defp name!(name, _key) when is_binary(name) and name != "", do: name
  defp name!(name, key), do: validate!(false, key, name)
end
