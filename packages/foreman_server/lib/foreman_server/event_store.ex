defmodule ForemanServer.EventStore do
  @moduledoc """
  Append-only event store shell with Postgres-compatible event envelopes.

  TRD-003 defines the Postgres schema in `priv/repo/migrations` and keeps this
  dependency-free term-log adapter as the runtime shell until the Postgres driver
  is introduced. The semantics are the same: validate envelope, enforce stream
  versions, persist append, then update projections.
  """

  use GenServer

  alias ForemanServer.{Event, EventCodec, ProjectionStore}

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
    path = event_log_path()
    File.mkdir_p!(Path.dirname(path))
    events = replay(path)
    Enum.each(events, &ProjectionStore.apply_event/1)
    {:ok, %{path: path, events: events}}
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
         :ok <- append_to_file(state.path, event) do
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

  defp event_log_path do
    Application.get_env(:foreman_server, :event_log_path) ||
      System.get_env("FOREMAN_SERVER_EVENT_LOG") ||
      Path.expand("var/foreman_server/events.term.log")
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

  defp append_to_file(path, %Event{} = event) do
    File.write(path, EventCodec.encode(event) <> "\n", [:append])
  end
end
