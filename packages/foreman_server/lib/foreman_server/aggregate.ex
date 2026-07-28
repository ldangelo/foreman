defmodule ForemanServer.Aggregate do
  alias Elixir.EventStore
  alias EventStore.EventData, as: EventData
  alias Commanded.EventStore.RecordedEvent, as: CommandedRecordedEvent

  @moduledoc """
  Behaviour for stateless aggregate modules.

  Each aggregate module implements this behaviour with pure functions.
  The supervised `Actor` GenServer holds the in-memory state and retains the
  authoritative stream version — obtained at load time and incremented on each
  confirmed append.

  ## Stream version

  The Actor retains `{module_state, version}` where `version` is the stream
  length at the time state was computed. This version is captured BEFORE
  `handle_command` is called — external appends while the parked actor cannot
  shift the baseline. On append success, version is incremented by the confirmed
  event count. On conflict, both state and version are unchanged.

  ## Event format

  Commands return typed event structs (`%ForemanServer.Events.RunStarted{}`).
  The `Actor` normalizes these into `%EventData{}` envelopes before sending to
  `CommandRouter`. On replay, `CommandedRecordedEvent` structs carry the persisted
  event_type string and decoded data map.
  """

  # Typed state for aggregate modules implementing this behaviour.
  @type aggregate_state() :: struct()

  @doc "Return the aggregate's initial (empty) state."
  @callback initial_state() :: aggregate_state()

  @typedoc "A typed domain event struct returned by handle_command."
  @type typed_event :: struct()

  @doc """
  Handle a command and return an event to be persisted.

  Return `{:ok, typed_event}` to emit one event.
  Return `{:ok, nil}` for read-only commands.
  Return `{:error, reason}` to reject the command.
  Return `:unhandled` to defer to a default implementation.
  """
  @callback handle_command(state :: aggregate_state(), command :: any()) ::
              {:ok, typed_event()}
              | {:ok, nil}
              | {:error, reason :: any()}
              | :unhandled

  @doc "Apply a persisted event to produce a new state."
  @callback apply_event(state :: aggregate_state(), event :: any()) :: aggregate_state()

  @doc """
  Rehydrate aggregate state from the event store.

  Called once on actor startup. Default implementation reads the aggregate's
  stream and reduces over all recorded events.
  """
  @callback load(aggregate_id :: String.t()) :: {aggregate_state(), version :: non_neg_integer()}

  @optional_callbacks [load: 1]

  # -------------------------------------------------------------------------
  # Helpers (used by aggregate implementations)
  # -------------------------------------------------------------------------

  @doc """
  Extract the event type string from an event.

  Handles:
  - `RecordedEvent{event_type: type}`              — from stream replay
  - `%{event_type: type}` / `%{type: type}`       — from handle_command output
  - `%{"event_type": type}` / `%{"type": type}`   — JSON-decoded map (TermSerializer)
  """
  @spec event_type(any()) :: String.t() | nil
  # RecordedEvent structs — match BEFORE the generic struct clause
  def event_type(%EventStore.RecordedEvent{event_type: type}), do: type
  def event_type(%CommandedRecordedEvent{event_type: type}), do: type
  # Typed domain event struct — derive event_type from module name
  def event_type(%{__struct__: _} = struct) when is_map(struct) do
    Module.split(struct.__struct__) |> List.last() |> Macro.underscore()
  end

  def event_type(%{event_type: type}), do: type
  def event_type(%{type: type}), do: type
  def event_type(%{"event_type" => type}), do: type
  def event_type(%{"type" => type}), do: type
  def event_type(_), do: nil

  @doc """
  Extract the event payload/data from an event.

  Handles:
  - `RecordedEvent{data: payload}`                  — from stream replay (TermSerializer)
  - `EventData{data: payload}`                     — from append path (TermOrJsonSerializer)
  - `%{payload: payload}`                          — from handle_command output
  - `%{"payload": payload}`                        — JSON-decoded map (TermSerializer)
  - A plain map itself                             — for already-decoded events
  """
  @spec event_payload(any()) :: map()
  def event_payload(%EventStore.RecordedEvent{data: data}) when is_map(data), do: data
  def event_payload(%CommandedRecordedEvent{data: data}) when is_map(data), do: data
  def event_payload(%EventData{data: data}) when is_map(data), do: data
  def event_payload(%{payload: payload}), do: payload
  def event_payload(%{"payload" => payload}), do: payload
  def event_payload(map) when is_map(map), do: map

  @doc """
  Get a value from a map, trying atom key first then string key.

  Used by aggregates that receive events as JSON maps (string keys) but
  internally use atom keys for struct-like state.
  """
  @spec get(map() | nil, atom() | String.t(), term()) :: term()
  def get(nil, _key, default), do: default

  def get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  def get(map, key, default) when is_map(map), do: Map.get(map, key, default)

  @doc "Get a value from a map with a nil default."
  @spec get(map() | nil, atom() | String.t()) :: term()
  def get(map, key), do: get(map, key, nil)

  @doc "Put a key/value into a map only if the value is non-nil."
  @spec put_if(map(), atom() | String.t(), term()) :: map()
  def put_if(map, _key, nil), do: map
  def put_if(map, key, value), do: Map.put(map, key, value)

  @doc "Validate that a required field is a non-empty binary."
  @spec required_binary(term(), atom() | String.t()) ::
          {:ok, binary()} | {:error, {:missing_or_invalid, atom() | String.t()}}
  def required_binary(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  def required_binary(_value, key), do: {:error, {:missing_or_invalid, key}}

  # -------------------------------------------------------------------------
  # Load (default implementation)
  # -------------------------------------------------------------------------

  @doc """
  Default rehydration: read all events from the aggregate's stream and reduce over them.

  Commanded.EventStore.stream_forward returns %Commanded.EventStore.RecordedEvent{}.
  We handle both RecordedEvent types via the event_type/event_payload clauses above.
  """
  @spec load(module, aggregate_id :: String.t()) ::
          {aggregate_state(), version :: non_neg_integer()}
  def load(module, aggregate_id) do
    case Commanded.EventStore.stream_forward(
           ForemanServer.CommandedApplication,
           aggregate_id,
           0,
           99_999_999
         ) do
      {:error, :stream_not_found} ->
        {module.initial_state(), 0}

      {:error, {:not_found, _, _}} ->
        {module.initial_state(), 0}

      stream ->
        events = Enum.to_list(stream)
        reduce_events(module, events)
    end
  end

  defp reduce_events(module, events) do
    {state, version} =
      Enum.reduce(events, {module.initial_state(), 0}, fn event, {state, n} ->
        {module.apply_event(state, event), n + 1}
      end)

    {state, version}
  end

  @doc false
  defmacro __using__(_opts) do
    quote location: :keep do
      @behaviour ForemanServer.Aggregate

      # Default load/1 delegates to ForemanServer.Aggregate.load/2.
      unless function_exported?(__MODULE__, :load, 1) do
        @impl true
        def load(aggregate_id) do
          ForemanServer.Aggregate.load(__MODULE__, aggregate_id)
        end
      end
    end
  end
end
