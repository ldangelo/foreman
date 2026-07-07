defmodule ForemanServer.EventStore do
  @moduledoc """
  Append-only event store with a Postgres/Ecto runtime backend.

  When `DATABASE_URL` (or `:database_url`) is configured, events are persisted to
  the `foreman_events` table through `ForemanServer.Repo`. Without a database URL
  the server keeps the legacy dependency-free term-log adapter for isolated tests
  and local transition scenarios.
  """

  use GenServer

  alias Ecto.Adapters.SQL
  alias ForemanServer.{Event, EventCodec, ProjectionStore, Repo}

  @type event :: Event.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec append(map()) :: {:ok, event()} | {:error, term()}
  def append(input) when is_map(input) do
    GenServer.call(__MODULE__, {:append, input})
  end

  @spec append(String.t(), map(), map()) :: {:ok, event()} | {:error, term()}
  def append(type, payload, metadata \\ %{})
      when is_binary(type) and is_map(payload) and is_map(metadata) do
    stream_id = Map.get(metadata, :stream_id) || Map.get(payload, :command_id) || type

    append(%{
      stream_id: "command:#{stream_id}",
      event_type: type,
      payload: payload,
      metadata: metadata,
      correlation_id: Map.get(metadata, :correlation_id)
    })
  end

  @spec all() :: [event()]
  def all do
    GenServer.call(__MODULE__, :all)
  end

  @spec stream(String.t()) :: [event()]
  def stream(stream_id) when is_binary(stream_id) do
    GenServer.call(__MODULE__, {:stream, stream_id})
  end

  @spec rebuild_projections() :: {:ok, map()}
  def rebuild_projections do
    GenServer.call(__MODULE__, :rebuild_projections)
  end

  @impl true
  def init(_opts) do
    adapter = adapter()
    events = load_events(adapter)
    Enum.each(events, &ProjectionStore.apply_event/1)
    {:ok, %{adapter: adapter, events: events}}
  end

  @impl true
  def handle_call({:append, input}, _from, state) do
    stream_id = Map.get(input, :stream_id)

    stream_version =
      if is_binary(stream_id), do: next_stream_version(state.events, stream_id), else: 1

    with :ok <- validate_stream_id(stream_id),
         :ok <- check_expected_version(input, stream_version),
         :ok <- check_idempotency(state.events, input),
         {:ok, event} <- Event.new(input, stream_version),
         :ok <- persist_event(state.adapter, event) do
      ProjectionStore.apply_event(event)
      notify_event_consumers(event)
      {:reply, {:ok, event}, %{state | events: state.events ++ [event]}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:all, _from, state) do
    {:reply, state.events, state}
  end

  def handle_call({:stream, stream_id}, _from, state) do
    events = Enum.filter(state.events, &(&1.stream_id == stream_id))
    {:reply, events, state}
  end

  def handle_call(:rebuild_projections, _from, state) do
    {:reply, ProjectionStore.rebuild(state.events), state}
  end

  defp adapter do
    case ForemanServer.RuntimeInfo.event_store_adapter() do
      :term -> {:term, ForemanServer.RuntimeInfo.event_log_path()}
      :postgres -> :postgres
    end
  end

  defp load_events(:postgres) do
    case SQL.query(Repo, """
         SELECT event_id, stream_id, stream_version, event_type, schema_version, payload,
                metadata, occurred_at, correlation_id, causation_id
         FROM foreman_events
         ORDER BY inserted_at ASC, stream_id ASC, stream_version ASC
         """) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, &row_to_event/1)

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        raise "failed to load foreman_events: table is missing; run Elixir event-store migrations or set FOREMAN_SERVER_EVENT_STORE_ADAPTER=term intentionally"

      {:error, reason} ->
        raise "failed to load foreman_events: #{inspect(reason)}"
    end
  end

  defp load_events({:term, path}) do
    File.mkdir_p!(Path.dirname(path))
    replay(path)
  end

  defp row_to_event([
         event_id,
         stream_id,
         stream_version,
         event_type,
         schema_version,
         payload,
         metadata,
         occurred_at,
         correlation_id,
         causation_id
       ]) do
    %Event{
      event_id: event_id,
      stream_id: stream_id,
      stream_version: stream_version,
      event_type: event_type,
      schema_version: schema_version,
      payload: atomize_keys(payload || %{}),
      metadata: atomize_keys(metadata || %{}),
      occurred_at: occurred_at,
      correlation_id: correlation_id,
      causation_id: causation_id
    }
  end

  defp persist_event(:postgres, %Event{} = event) do
    params = [
      event.event_id,
      event.stream_id,
      event.stream_version,
      event.event_type,
      event.schema_version,
      stringify_keys(event.payload),
      stringify_keys(event.metadata),
      event.occurred_at,
      event.correlation_id,
      event.causation_id
    ]

    case SQL.query(
           Repo,
           """
           INSERT INTO foreman_events (
             event_id, stream_id, stream_version, event_type, schema_version,
             payload, metadata, occurred_at, correlation_id, causation_id
           ) VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7::jsonb, $8, $9, $10)
           """,
           params
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_event({:term, path}, %Event{} = event) do
    File.write(path, EventCodec.encode(event) <> "\n", [:append])
  end

  defp validate_stream_id(stream_id) when is_binary(stream_id) and stream_id != "", do: :ok
  defp validate_stream_id(_stream_id), do: {:error, {:missing_or_invalid, :stream_id}}

  defp check_expected_version(input, next_version) do
    case Map.fetch(input, :expected_stream_version) do
      {:ok, expected} when expected == next_version - 1 -> :ok
      {:ok, expected} -> {:error, {:conflict, expected: expected, actual: next_version - 1}}
      :error -> :ok
    end
  end

  defp check_idempotency(events, input) do
    idempotency_key = input |> Map.get(:metadata, %{}) |> Map.get(:idempotency_key)

    duplicate? =
      is_binary(idempotency_key) and
        Enum.any?(events, fn event ->
          event.stream_id == input.stream_id and
            Map.get(event.metadata, :idempotency_key) == idempotency_key
        end)

    if duplicate?, do: {:error, {:duplicate_idempotency_key, idempotency_key}}, else: :ok
  end

  defp next_stream_version(events, stream_id) do
    events
    |> Enum.filter(&(&1.stream_id == stream_id))
    |> Enum.map(& &1.stream_version)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp replay(path) do
    if File.exists?(path) do
      path
      |> File.stream!([], :line)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&EventCodec.decode/1)
      |> Enum.map(fn
        {:ok, event} -> event
        {:error, reason} -> raise "invalid event in #{path}: #{inspect(reason)}"
      end)
    else
      []
    end
  end

  defp notify_event_consumers(%Event{} = event) do
    if Process.whereis(ForemanServer.Scheduler) do
      ForemanServer.Scheduler.handle_event(event)
    end

    ForemanServer.Overwatch.handle_event(event)

    :ok
  end

  defp stringify_keys(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp stringify_keys(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
    |> Map.new()
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp atomize_keys(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {safe_atom(key), atomize_keys(nested)} end)
    |> Map.new()
  end

  defp atomize_keys(value) when is_list(value), do: Enum.map(value, &atomize_keys/1)
  defp atomize_keys(value), do: value

  defp safe_atom(key) when is_atom(key), do: key
  defp safe_atom(key) when is_binary(key), do: String.to_atom(key)
end
