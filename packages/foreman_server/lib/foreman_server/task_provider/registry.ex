defmodule ForemanServer.TaskProvider.Registry do
  @moduledoc """
  In-memory registry of `ForemanServer.TaskProvider` implementations.

  Loads configured providers at boot and exposes an atomic routing snapshot for
  the dispatch path.

  Restart strategy: `:permanent` (must be supervised with `restart: :permanent`).
  Emits `[:foreman_server, :task_provider, :registry, :restarted]` on each
  restart after the initial boot.
  """

  use GenServer

  alias ForemanServer.TaskProvider
  alias ForemanServer.TaskProvider.Telemetry, as: TaskProviderTelemetry

  require Logger

  @restart_event [:foreman_server, :task_provider, :registry, :restarted]
  @route_event_prefix [:foreman_server, :task_provider, :registry, :route]
  @required_callbacks TaskProvider.behaviour_info(:callbacks)

  @type state :: %{
          routing: %{atom() => module()},
          accepted_versions: [String.t()]
        }

  ## Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Atomic snapshot of `%{provider_id => provider_module}` for the dispatch path.
  """
  @spec routing_snapshot() :: %{atom() => module()}
  def routing_snapshot do
    GenServer.call(__MODULE__, :routing_snapshot)
  end

  @spec route(transition :: atom(), routing_key :: term()) ::
          {:ok, module()} | {:error, atom()}
  def route(transition, routing_key) when is_atom(transition) do
    GenServer.call(__MODULE__, {:route, transition, routing_key})
  end

  @doc """
  Manually register a provider (rare; usually loaded at boot).
  """
  @spec register(module()) ::
          {:ok, module()}
          | {:error, :contract_version_mismatch | :invalid_module | :unavailable}
  def register(provider_module) when is_atom(provider_module) do
    GenServer.call(__MODULE__, {:register, provider_module})
  end

  def register(_provider_module), do: {:error, :invalid_module}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  ## GenServer callbacks

  @impl true
  def init(opts) do
    {accepted_versions, providers} = provider_config()
    routing = load_providers(providers, accepted_versions)
    server_name = Keyword.get(opts, :name, __MODULE__)

    maybe_emit_restart_telemetry(server_name, routing)

    {:ok, %{routing: routing, accepted_versions: accepted_versions}}
  end

  @impl true
  def handle_call(:routing_snapshot, _from, state) do
    {:reply, state.routing, state}
  end

  def handle_call({:register, provider_module}, _from, state) do
    case register_provider(provider_module, state.routing, state.accepted_versions) do
      {:ok, _provider_id, routing} ->
        {:reply, {:ok, provider_module}, %{state | routing: routing}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:route, transition, routing_key}, _from, state) do
    case route_provider(state.routing, transition, routing_key) do
      {:ok, provider_module} = ok ->
        TaskProviderTelemetry.emit(@route_event_prefix ++ [:ok], %{count: 1}, %{
          transition: transition,
          routing_key: routing_key,
          provider: provider_module
        })

        {:reply, ok, state}

      {:error, reason} = error ->
        TaskProviderTelemetry.emit(@route_event_prefix ++ [:error], %{count: 1}, %{
          transition: transition,
          routing_key: routing_key,
          reason: reason
        })

        {:reply, error, state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  ## Internal

  defp provider_config do
    config = Application.get_env(:foreman_server, :task_provider, [])
    {config[:accepted_contract_versions] || [], config[:providers] || []}
  end

  defp load_providers(providers, accepted_versions) do
    Enum.reduce(providers, %{}, fn provider_module, routing ->
      case register_provider(provider_module, routing, accepted_versions) do
        {:ok, _provider_id, new_routing} ->
          new_routing

        {:error, reason} ->
          Logger.warning("skipping task provider #{inspect(provider_module)}: #{inspect(reason)}")
          routing
      end
    end)
  end

  defp register_provider(provider_module, routing, accepted_versions) do
    with :ok <- ensure_provider_module(provider_module),
         capabilities <- provider_module.capabilities(),
         :ok <- ensure_contract_version(capabilities, accepted_versions),
         :ok <- ensure_available(provider_module) do
      provider_id = provider_id(provider_module, capabilities)
      {:ok, provider_id, Map.put(routing, provider_id, provider_module)}
    end
  end

  defp ensure_provider_module(provider_module) when is_atom(provider_module) do
    if Code.ensure_loaded?(provider_module) and
         Enum.all?(@required_callbacks, fn {name, arity} ->
           function_exported?(provider_module, name, arity)
         end) do
      :ok
    else
      {:error, :invalid_module}
    end
  end

  defp ensure_provider_module(_provider_module), do: {:error, :invalid_module}

  defp ensure_contract_version(capabilities, accepted_versions) do
    if capabilities[:contract_version] in accepted_versions do
      :ok
    else
      {:error, :contract_version_mismatch}
    end
  end

  defp ensure_available(provider_module) do
    case provider_module.available?() do
      true -> :ok
      false -> {:error, :unavailable}
    end
  end

  defp route_provider(routing, transition, routing_key) do
    routing
    |> Map.values()
    |> Enum.find(fn provider_module ->
      supports_transition?(provider_module, transition) and
        routing_key_match?(provider_module, routing_key)
    end)
    |> case do
      nil -> {:error, :no_provider_for_transition}
      provider_module -> {:ok, provider_module}
    end
  end

  defp supports_transition?(provider_module, transition) do
    provider_module
    |> provider_capabilities()
    |> Map.get(:supports, [])
    |> Enum.member?(transition)
  end

  defp routing_key_match?(_provider_module, nil), do: true

  defp routing_key_match?(provider_module, routing_key) do
    provider_module.name() == routing_key
  end

  defp provider_capabilities(provider_module), do: provider_module.capabilities()

  defp provider_id(provider_module, capabilities) do
    capabilities[:provider_id] || provider_module.name()
  end

  defp maybe_emit_restart_telemetry(server_name, routing) do
    marker = {__MODULE__, server_name, :boot_count}

    case :persistent_term.get(marker, 0) do
      0 ->
        :persistent_term.put(marker, 1)

      boot_count when is_integer(boot_count) ->
        next_boot_count = boot_count + 1
        :persistent_term.put(marker, next_boot_count)

        TaskProviderTelemetry.emit(@restart_event, %{count: 1}, %{
          restart_count: next_boot_count - 1,
          providers: Map.keys(routing),
          registry: server_name
        })
    end
  end
end
