defmodule ForemanServer.EventStore do
  @moduledoc "Dependency-free durable event log used by the initial OTP shell."

  use GenServer

  alias ForemanServer.ProjectionStore

  @type event :: %{
          required(:type) => String.t(),
          required(:payload) => map(),
          required(:metadata) => map(),
          required(:sequence) => non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec append(String.t(), map(), map()) :: {:ok, event()} | {:error, term()}
  def append(type, payload, metadata \\ %{})
      when is_binary(type) and is_map(payload) and is_map(metadata) do
    GenServer.call(__MODULE__, {:append, type, payload, metadata})
  end

  @spec all() :: [event()]
  def all do
    GenServer.call(__MODULE__, :all)
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
  def handle_call({:append, type, payload, metadata}, _from, state) do
    event = %{
      type: type,
      payload: payload,
      metadata: Map.put_new(metadata, :recorded_at, DateTime.utc_now()),
      sequence: length(state.events) + 1
    }

    case append_to_file(state.path, event) do
      :ok ->
        ProjectionStore.apply_event(event)
        {:reply, {:ok, event}, %{state | events: state.events ++ [event]}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:all, _from, state) do
    {:reply, state.events, state}
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
      |> Enum.map(fn line ->
        line
        |> Base.decode64!()
        |> :erlang.binary_to_term()
      end)
    else
      []
    end
  end

  defp append_to_file(path, event) do
    line = event |> :erlang.term_to_binary() |> Base.encode64()
    File.write(path, line <> "\n", [:append])
  end
end
