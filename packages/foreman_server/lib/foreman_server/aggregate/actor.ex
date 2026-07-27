defmodule ForemanServer.Aggregate.Actor do
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

  alias ForemanServer.{Aggregate, CommandRouter}
  alias EventStore.EventData

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

    state = %{
      aggregate_module: aggregate_module,
      aggregate_id: aggregate_id,
      module_state: module_state,
      version: version
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state.module_state, state}
  end

  @impl true
  def handle_call({:command, cmd}, _from, state) do
    aggregate_module = state.aggregate_module
    aggregate_id = state.aggregate_id
    # Capture version BEFORE handle_command — external appends while parked
    # must not shift the baseline for this command's append.
    expected_version = state.version

    case aggregate_module.handle_command(state.module_state, cmd) do
      {:ok, nil} ->
        {:reply, {:ok, nil}, state}

      {:ok, event_spec} when is_map(event_spec) ->
        event_data = normalize_to_event_data(event_spec)
        ref = make_ref()

        send(CommandRouter, {:append, aggregate_id, [event_data], expected_version, ref, self()})

        receive do
          {:append_ok, ^ref, _event_count} ->
            new_module_state = aggregate_module.apply_event(state.module_state, event_spec)
            new_version = state.version + 1
            {:reply, {:ok, event_spec},
             %{state | module_state: new_module_state, version: new_version}}

          {:error, ^ref, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  # -------------------------------------------------------------------------
  # Internal
  # -------------------------------------------------------------------------

  # Convert event_spec map to %EventData{} for append.
  defp normalize_to_event_data(%{stream_id: _stream_id, event_type: event_type, payload: payload}) do
    %EventData{event_type: event_type, data: payload}
  end

  # Already an %EventData{} — pass through (defensive for test fixtures).
  defp normalize_to_event_data(%EventData{} = ed), do: ed
end
