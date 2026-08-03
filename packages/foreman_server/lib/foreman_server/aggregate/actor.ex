defmodule ForemanServer.Aggregate.Actor do
  import Bitwise
  @moduledoc """
  Supervised GenServer that holds aggregate state and stream version.

  The Actor retains `{module_state, version}` where `version` is the stream
  length at the time state was computed — captured BEFORE `handle_command` is called.
  This prevents external appends (while parked) from shifting the append baseline.

  ## Event spec vs persistence

  - `handle_command` returns `{:ok, event_spec}` where `event_spec` is a map:
      `%{stream_id: "...", event_type: "...", payload: %{...}}`
    Or `{:ok, nil}` for no-op commands.
  - Actor normalizes `event_spec` → `%EventData{}` for `append_to_stream`.
  - After append confirmed, Actor calls `apply_event(state, event_spec)`.
    The aggregate uses `Aggregate.event_type/1` and `Aggregate.event_payload/1`
    to extract from the spec map — these helpers also accept `RecordedEvent` structs
    for normal replay via `Aggregate.load/1`.

  ## Actor ↔ CommandRouter protocol

  1. Actor receives `{:command, cmd}` from caller.
  2. Actor captures `expected_version` — BEFORE `handle_command`.
  3. Actor calls `aggregate_module.handle_command(current_state, cmd)`.
  4. Actor generates a correlation `ref = make_ref()` and sends
     `{:append, aggregate_id, event_data_list, expected_version, ref, self()}` to CommandRouter.
  5. Actor waits in selective `receive` for `{:append_ok, ^ref, count}` or `{:error, ^ref, reason}`.
     Using `^ref` ensures only the matching reply satisfies the receive;
     stale/foreign replies remain queued and are handled later.
  6. CommandRouter appends events and replies with the same `ref`.
  7. Actor applies confirmed events and:
     - On success: bumps version by 1, returns `{:reply, {:ok, event_spec}, new_state}`
     - On conflict/error: version unchanged, returns `{:reply, {:error, reason}, old_state}`
  """

  alias ForemanServer.{Aggregate, CommandRouter, Telemetry}
  alias EventStore.EventData
  alias ForemanServer.EventStore

  use GenServer

  # -------------------------------------------------------------------------
  # Client
  # -------------------------------------------------------------------------

  @spec start_link(module, aggregate_id :: String.t()) :: GenServer.on_start()
  def start_link(aggregate_module, aggregate_id) do
    GenServer.start_link(__MODULE__, {aggregate_module, aggregate_id}, name: via(aggregate_id))
  end

  @doc "Return the aggregate module's current in-memory state."
  @spec get_state(pid) :: any()
  def get_state(pid), do: GenServer.call(pid, :get_state)

  @doc "Registry key for an aggregate actor."
  def via(aggregate_id) do
    {:via, Registry, {ForemanServer.AggregateRegistry, aggregate_id}}
  end

  # -------------------------------------------------------------------------
  # Callbacks
  # -------------------------------------------------------------------------

  @impl true
  def init({aggregate_module, aggregate_id}) do
    # Aggregate may implement load/1; if not, use the default Aggregate.load/2
    # (replays stream_forward through apply_event).
    {module_state, version} =
      if function_exported?(aggregate_module, :load, 1) do
        aggregate_module.load(aggregate_id)
      else
        Aggregate.load(aggregate_module, aggregate_id)
      end
    Telemetry.aggregate_rehydrated(version)

    Phoenix.PubSub.broadcast(ForemanServer.PubSub, "debug:aggregates", {:actor_loaded, aggregate_id})
    track_presence(aggregate_id, aggregate_module, version)

    state = %{
      aggregate_module: aggregate_module,
      aggregate_id: aggregate_id,
      module_state: module_state,
      version: version
    }

    {:ok, state}
  end

  defp track_presence(aggregate_id, aggregate_module, version) do
    ForemanServerWeb.Presence.track(self(), "debug:aggregates", aggregate_id, %{
      aggregate_id: aggregate_id,
      module: inspect(aggregate_module),
      version: version
    })
  end

  defp update_presence(aggregate_id, aggregate_module, version) do
    ForemanServerWeb.Presence.update(self(), "debug:aggregates", aggregate_id, fn _meta ->
      %{
        aggregate_id: aggregate_id,
        module: inspect(aggregate_module),
        version: version
      }
    end)
  end
  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state.module_state, state}
  end

  @impl true
  def handle_call({:command, cmd}, _from, state) do
    aggregate_module = state.aggregate_module
    aggregate_id = state.aggregate_id
    expected_version = state.version

    # -------------------------------------------------------------------------
    # AC2: Idempotent command handling via deterministic event_id.
    # event_id is derived from {aggregate_id, command_id}. We pre-check the
    # aggregate's stream for this event_id BEFORE handle_command to avoid
    # hitting terminal-state rejection paths on duplicate commands.
    #
    # read_event_by_id is NOT used here — it queries columns that do not exist
    # in the current EventStore v0.14+ schema (event_number, stream_uuid,
    # stream_version were dropped from the events table). read_stream_forward
    # works correctly and is used instead.
    # -------------------------------------------------------------------------
    event_id =
      case cmd do
        %{command_id: command_id} when is_binary(command_id) ->
          derive_event_id(aggregate_id, command_id)
        _ ->
          nil
      end

    # Pre-check for duplicate: if this event_id already exists in the stream,
    # return the existing event as an idempotent success — skip handle_command
    # to avoid terminal-state rejections on stale state reads.
    if event_id && duplicate_in_stream?(aggregate_id, event_id) do
      {:reply, {:ok, existing_event_spec(aggregate_id, event_id)}, state}
    else
      case aggregate_module.handle_command(state.module_state, cmd) do
        {:ok, nil} ->
          {:reply, {:ok, nil}, state}

        {:ok, event_spec} when is_map(event_spec) ->
          event_data = normalize_to_event_data(event_spec, event_id)
          ref = make_ref()

          send(CommandRouter, {:append, aggregate_id, [event_data], expected_version, ref, self()})

          receive do
            {:append_ok, ^ref, _event_count, append_latency_ms} ->
              new_module_state = aggregate_module.apply_event(state.module_state, event_spec)
              new_version = state.version + 1
              update_presence(aggregate_id, aggregate_module, new_version)

              {:reply, {:telemetry, {:ok, to_string_keys(event_spec)}, %{append_latency_ms: append_latency_ms}},
               %{state | module_state: new_module_state, version: new_version}}

            {:append_ok, ^ref, _event_count} ->
              new_module_state = aggregate_module.apply_event(state.module_state, event_spec)
              new_version = state.version + 1
              update_presence(aggregate_id, aggregate_module, new_version)
              {:reply, {:telemetry, {:ok, to_string_keys(event_spec)}, %{append_latency_ms: 0}},
               %{state | module_state: new_module_state, version: new_version}}
            {:error, ^ref, :duplicate_event, append_latency_ms} ->
              {:reply, {:telemetry, {:ok, existing_event_spec(aggregate_id, event_id)},
                        %{append_latency_ms: append_latency_ms}}, state}

            {:error, ^ref, :duplicate_event} ->
              {:reply, {:telemetry, {:ok, existing_event_spec(aggregate_id, event_id)},
                        %{append_latency_ms: 0}}, state}

            {:error, ^ref, reason, append_latency_ms} ->
              {:reply, {:telemetry, {:error, reason}, %{append_latency_ms: append_latency_ms}}, state}

            {:error, ^ref, reason} ->
              {:reply, {:telemetry, {:error, reason}, %{append_latency_ms: 0}}, state}
          end

        {:error, _reason} = error ->
          {:reply, error, state}
      end
    end
  end

  # -------------------------------------------------------------------------
  # Internal
  # -------------------------------------------------------------------------

  # Convert event_spec map to %EventData{} for append.
  # When event_id is provided (commands with command_id), it is set on the
  # %EventData{} so EventStore uses it as the persisted event_id — enabling
  # database-level deduplication via the events_pkey unique constraint.
  defp normalize_to_event_data(%{stream_id: _stream_id, event_type: event_type, payload: payload}, event_id) do
    %EventData{event_id: event_id, event_type: event_type, data: payload}
  end

  # Already an %EventData{} — pass through (defensive for test fixtures).
  defp normalize_to_event_data(%EventData{} = ed, _event_id), do: ed
  # -------------------------------------------------------------------------
  # Helpers: event_spec format conversion for caller-facing returns
  # -------------------------------------------------------------------------

  # Recursively convert atom-keyed maps to string-keyed maps (for event_spec).
  defp to_string_keys(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> to_string_keys()
  end

  defp to_string_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {k, v}, acc when is_atom(k) ->
        Map.put(acc, Atom.to_string(k), to_string_keys(v))

      {k, v}, acc when is_binary(k) ->
        Map.put(acc, k, to_string_keys(v))
    end)
  end

  defp to_string_keys(other), do: other
  # Convert a stored %RecordedEvent{} to an event_spec map with string keys.
  # Used for returning existing events on duplicate idempotent hits.
  defp recorded_event_to_event_spec(recorded) do
    %{"stream_id" => recorded.stream_uuid, "event_type" => recorded.event_type,
      "payload" => recorded.data}
  end

  # -------------------------------------------------------------------------
  # AC2: Deterministic event_id and idempotency
  # -------------------------------------------------------------------------

  # Derive a deterministic event_id from {aggregate_id, command_id}.
  # Uses SHA-256 to produce a valid 32-hex-char UUID string.
  # The same {aggregate_id, command_id} always produces the same event_id.
  defp derive_event_id(aggregate_id, command_id) do
    <<first16::binary-size(16), _::binary>> = :crypto.hash(:sha256, aggregate_id <> command_id)
    <<b0::8, b1::8, b2::8, b3::8, b4::8, b5::8, b6::8, b7::8, b8::8,
      b9::8, b10::8, b11::8, b12::8, b13::8, b14::8, b15::8>> =
      first16

    b6 = bor(band(b6, 0x0F), 0x40)
    b8 = bor(band(b8, 0x3F), 0x80)

    Elixir.EventStore.UUID.binary_to_string!(<<b0::8, b1::8, b2::8, b3::8, b4::8, b5::8, b6::8, b7::8,
                                     b8::8, b9::8, b10::8, b11::8, b12::8, b13::8, b14::8, b15::8>>)
  end

  # Check if an event with the given event_id already exists in the aggregate's stream.
  # Uses read_stream_forward (works with current EventStore schema) instead of
  # the broken read_event_by_id (queries non-existent event_number column).
  defp duplicate_in_stream?(aggregate_id, event_id) do
    case EventStore.read_stream_forward(aggregate_id, 0, 100) do
      {:ok, events} ->
        Enum.any?(events, fn %Elixir.EventStore.RecordedEvent{event_id: id} -> id == event_id end)
      {:error, _} ->
        false
    end
  end

  # Find and return the event_spec for an existing event by its event_id.
  # Reads the aggregate's stream and returns the matching event's spec.
  defp existing_event_spec(aggregate_id, event_id) do
    {:ok, events} = EventStore.read_stream_forward(aggregate_id, 0, 100)
    recorded = Enum.find(events, fn %Elixir.EventStore.RecordedEvent{event_id: id} -> id == event_id end)
    recorded_event_to_event_spec(recorded)
  end
end
