defmodule ForemanServer.JidoSignal.Subscriber do
  @moduledoc """
  Subscriber for ForemanServer Jido signals.

  Provides a GenServer that subscribes to the signal bus and dispatches
  signals to registered handlers.
  """

  use GenServer
  require Logger

  alias Jido.Signal.Bus
  alias Jido.Signal

  @type handler :: {module(), atom(), keyword()}
  @type topic :: String.t()

  @doc """
  Starts the subscriber GenServer.

  ## Options
  - `:bus` - The signal bus name (default: :foreman_signal_bus)
  - `:topics` - List of topics to subscribe to
  - `:handlers` - Map of handler modules to their callback functions
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    bus = Keyword.get(opts, :bus, :foreman_signal_bus)
    topics = Keyword.get(opts, :topics, [])
    handlers = Keyword.get(opts, :handlers, %{})

    GenServer.start_link(__MODULE__, {bus, topics, handlers}, name: __MODULE__)
  end

  @impl true
  def init({bus, topics, handlers}) do
    Process.flag(:trap_exit, true)

    # Subscribe to all specified topics
    Enum.each(topics, fn topic ->
      Bus.subscribe(bus, topic, self())
      Logger.debug("Subscribed to topic: #{topic}")
    end)

    {:ok, %{bus: bus, topics: topics, handlers: handlers, state: :running}}
  end

  @impl true
  def handle_info({:signal, signal}, %{state: :running} = state) do
    Logger.debug("Received signal: #{inspect(signal)}")

    # Dispatch signal to appropriate handler based on topic
    case Map.get(state.handlers, signal.topic) do
      nil ->
        Logger.warning("No handler for topic: #{signal.topic}")

      {module, func, opts} ->
        try do
          apply(module, func, [signal | opts])
        rescue
          error ->
            Logger.error("Error dispatching signal: #{Exception.message(error)}")
        end
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:shutdown, state) do
    {:stop, :normal, %{state | state: :stopped}}
  end

  @doc """
  Subscribes to a topic from a running subscriber.
  """
  @spec subscribe(topic()) :: :ok
  def subscribe(topic) do
    GenServer.call(__MODULE__, {:subscribe, topic})
  end

  @impl true
  def handle_call({:subscribe, topic}, _from, state) do
    Bus.subscribe(state.bus, topic, self())
    Logger.debug("Subscribed to topic: #{topic}")
    {:reply, :ok, state}
  end

  @doc """
  Unsubscribes from a topic.
  """
  @spec unsubscribe(topic()) :: :ok
  def unsubscribe(topic) do
    GenServer.call(__MODULE__, {:unsubscribe, topic})
  end

  @impl true
  def handle_call({:unsubscribe, topic}, _from, state) do
    Bus.unsubscribe(state.bus, topic, self())
    Logger.debug("Unsubscribed from topic: #{topic}")
    {:reply, :ok, state}
  end
end
