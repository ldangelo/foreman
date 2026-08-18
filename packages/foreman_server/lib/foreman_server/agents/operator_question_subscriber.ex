defmodule ForemanServer.Agents.OperatorQuestionSubscriber do
  @moduledoc """
  Foreman-side bus subscriber that consumes `com.foreman.operator.*`
  signals (TRD-2026-4212be7e, JSI-T006).

  The TRD pairs this subscriber with the inbox-API dispatch
  adapter (JSI-T007) and the full operator-question → inbox →
  directive flow (JSI-T008). This module is the bus-side wire:

  1. `start_link/1` subscribes the GenServer's pid to the operator
     topic on the supplied bus.
  2. Each incoming `:signal` message is delegated to
     `ForemanServer.Agents.OperatorQuestionDispatcher.dispatch/1`
     (JSI-T007), which converts the CloudEvent envelope to the
     Foreman inbox pipeline (`ForemanServer.Inbox.SharedInbox`).

  The subscriber's own behavior is intentionally minimal — the
  actual inbox conversion lives in JSI-T007 so this module can be
  tested without booting the inbox pipeline.
  """

  use GenServer

  require Logger

  alias ForemanServer.Agents.OperatorQuestionDispatcher
  alias ForemanServer.Agents.JidoSignalTopics

  @operator_topic "com.foreman.operator.*"

  @doc """
  Start the subscriber and subscribe its pid to the operator topic
  on the given bus.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    bus = Keyword.fetch!(opts, :bus)

    case Jido.Signal.Bus.subscribe(bus, @operator_topic,
           dispatch: {:pid, target: self()}
         ) do
      :ok ->
        {:ok, %{bus: bus, subscription_ref: nil}}

      {:ok, ref} ->
        {:ok, %{bus: bus, subscription_ref: ref}}

      other ->
        Logger.warning(
          "OperatorQuestionSubscriber: failed to subscribe to #{inspect(bus)}: #{inspect(other)}"
        )

        {:stop, {:subscribe_failed, other}}
    end
  end

  @impl true
  def handle_info({:signal, signal}, state) do
    OperatorQuestionDispatcher.dispatch(signal)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc """
  Sanity helper: the operator topic pattern this subscriber consumes.
  Exposed so tests and supervisors can assert the wiring shape.
  """
  @spec operator_topic() :: String.t()
  def operator_topic, do: @operator_topic

  @doc """
  Sanity helper: the same topic exposed via `JidoSignalTopics`.
  """
  @spec topic_via_signal_topics() :: String.t()
  def topic_via_signal_topics, do: JidoSignalTopics.foreman_operator()
end
