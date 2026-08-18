defmodule ForemanServer.Agents.TaskMetadataQuerySubscriber do
  @moduledoc """
  Foreman-side bus subscriber that consumes
  `com.foreman.query.task_metadata.*` query signals and publishes
  responses back to the requesting agent (TRD-2026-4212be7e, JSI-T012).

  This is the production wire for the Agent↔Foreman query/response
  flow:

  1. `start_link/1` starts a GenServer; on init it subscribes the
     GenServer's pid to the query topic on the supplied bus
     (typically `:foreman_jido_signal_bus` — the always-on production
     bus; see `ForemanServer.Application.maybe_jido_signal_bus_child/0`).
  2. Each incoming query signal is handled by
     `TaskMetadataQueryResponder.respond/3`, which:
     - extracts `task_id`, `agent_id`, and `query_id` from the signal data,
     - looks up the task via the injected reader
       (`ProjectionStore.task_projection/1` — the read model, NOT
       `TaskProvider.get/2`, which is for upstream integration),
     - builds a `{:ok, metadata}` or `{:error, reason}` response signal,
     - publishes the response to the agent on its
       `agents.<id>.directive` topic via
       `SignalDirectivePublisher.publish/3`.
  """

  use GenServer

  require Logger

  alias ForemanServer.Agents.SignalDirectivePublisher
  alias ForemanServer.Agents.TaskMetadataQueryResponder
  alias ForemanServer.ProjectionStore

  @query_topic "com.foreman.query.task_metadata.*"

  @doc """
  Start the subscriber and subscribe its pid to the query topic on
  the given bus.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    bus = Keyword.fetch!(opts, :bus)

    case Jido.Signal.Bus.subscribe(bus, @query_topic,
           dispatch: {:pid, target: self()}
         ) do
      :ok ->
        {:ok, %{bus: bus, subscription_ref: nil}}

      {:ok, ref} ->
        {:ok, %{bus: bus, subscription_ref: ref}}

      other ->
        Logger.warning(
          "TaskMetadataQuerySubscriber: failed to subscribe to #{inspect(bus)}: #{inspect(other)}"
        )

        {:stop, {:subscribe_failed, other}}
    end
  end

  @impl true
  def handle_info({:signal, signal}, state) do
    handle_query(signal, state.bus)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Handle a query signal end-to-end. Public so the test (and the
  # future JSI-T013 integration test) can drive the responder without
  # going through the bus.
  @doc false
  @spec handle_query(struct(), GenServer.server()) :: :ok
  def handle_query(%Jido.Signal{} = signal, bus) do
    TaskMetadataQueryResponder.respond(signal, bus, &read_metadata/1)
  end

  @doc """
  Default metadata reader — wraps `ProjectionStore.task_projection/1`
  and normalizes `nil` to `{:error, :not_found}` so the rest of the
  responder pipeline sees only `{:ok, term()}` or `{:error, term()}`.
  """
  @spec read_metadata(String.t()) :: {:ok, map()} | {:error, term()}
  def read_metadata(task_id) when is_binary(task_id) do
    case ProjectionStore.task_projection(task_id) do
      nil -> {:error, :not_found}
      map when is_map(map) -> {:ok, map}
    end
  end

  @doc """
  Sanity helper: the query topic pattern this subscriber consumes.
  """
  @spec query_topic() :: String.t()
  def query_topic, do: @query_topic
end
