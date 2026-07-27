defmodule ForemanServer.Aggregate do
  alias Elixir.EventStore
  alias EventStore.EventData, as: EventData

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

  Aggregates return event specs as maps:
  `%{stream_id: "...", event_type: "...", payload: %{...}}`.

  The Actor normalizes these to `%EventData{}` for `append_to_stream`.
  After append confirmed, Actor calls `apply_event(state, event_spec)` with the
  event spec map — NOT the EventData struct. Helpers below accept both the
  event spec map and `RecordedEvent{data: payload}` from stream replay.
  """

  # Typed state for aggregate modules implementing this behaviour.
  @type aggregate_state() :: struct()

  @doc "Return the aggregate's initial (empty) state."
  @callback initial_state() :: aggregate_state()

  @doc """
  Decide a command and return an event spec.

  Called by the `Actor` after rehydration. Return:
  - `{:ok, event_spec}`  — event as map with `stream_id`, `event_type`, `payload`
  - `{:ok, nil}`         — command was a no-op (e.g., duplicate detected)
  - `{:error, reason}`    — command rejected, state unchanged
  - `:unhandled`          — command not recognised, state unchanged (no append)
  """
  @callback handle_command(state :: aggregate_state(), command :: any()) ::
              {:ok, event_spec :: map()}
              | {:ok, nil}
              | {:error, reason :: any()}
              | :unhandled

  @doc """
  Apply a confirmed event to aggregate state.

  Called only after `EventStore.append_to_stream` succeeds (append-then-apply).
  Receives either a `RecordedEvent{data: payload}` (from stream replay via
  `Aggregate.load/2`) or an event spec map (from `handle_command` output when
  the Actor applies the confirmed event for in-memory state).
  Use `event_type/1` and `event_payload/1` to extract in a shape-independent way.
  """
  @callback apply_event(state :: aggregate_state(), event :: any()) :: aggregate_state()

  @doc """
  Rehydrate aggregate state from the event stream.

  Called by the `Actor` on startup and after every restart.
  Returns `{state, version}` where version is the stream length at load time.

  Aggregates may override this with a custom implementation.
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
  - `%{"event_type": type}` / `%{"type": type}`  — JSON-decoded map (TermSerializer)
  """
  @spec event_type(any()) :: String.t() | nil
  def event_type(%EventStore.RecordedEvent{event_type: type}), do: type
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
  def event_payload(%EventData{data: data}) when is_map(data), do: data
  def event_payload(%EventData{}), do: raise("EventData.data is not a decoded map")
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

  @doc """
  Conditionally put a key into a map — no-op if value is nil.

  Used to avoid polluting state with nil fields.
  """
  @spec put_if(map(), atom() | String.t(), term()) :: map()
  def put_if(map, _key, nil), do: map
  def put_if(map, key, value), do: Map.put(map, key, value)

  @doc """
  Validate that a required field is present and a non-empty binary.

  Returns `{:ok, value}` or `{:error, {:missing_or_invalid, key}}`.
  """
  @spec required_binary(term(), atom() | String.t()) ::
          {:ok, binary()} | {:error, {:missing_or_invalid, atom() | String.t()}}
  def required_binary(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  def required_binary(_value, key), do: {:error, {:missing_or_invalid, key}}

  # -------------------------------------------------------------------------
  # Load (default implementation)
  # -------------------------------------------------------------------------

  @doc """
  Rehydrate aggregate state and stream version by replaying events.

  Uses `read_stream_forward` (returns `{:ok, events}` — a concrete list, NOT a Stream)
  then folds through `apply_event/2` while counting events in a single `Enum.reduce` pass.
  Returns `{aggregate_state(), version}` where version is the number of events.

  Called by the `Actor` on startup and after every restart.
  """
  @spec load(module, aggregate_id :: String.t()) ::
          {aggregate_state(), version :: non_neg_integer()}
  def load(module, aggregate_id) do
    case ForemanServer.EventStore.read_stream_forward(aggregate_id, 0, 99_999_999) do
      {:error, :stream_not_found} ->
        {module.initial_state(), 0}

      {:ok, events} ->
        {state, version} =
          Enum.reduce(events, {module.initial_state(), 0}, fn event, {state, n} ->
            {module.apply_event(state, event), n + 1}
          end)

        {state, version}
    end
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
