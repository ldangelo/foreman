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
  @per_project_register_event_prefix [
    :foreman_server,
    :task_provider,
    :registry,
    :register_for_project
  ]
  @per_project_unregister_event [
    :foreman_server,
    :task_provider,
    :registry,
    :unregister_for_project
  ]
  @required_callbacks TaskProvider.behaviour_info(:callbacks)

  @type per_project_state ::
          {:active, %{provider_module: module(), config: map()}}
          | {:unavailable, atom()}
  @type state :: %{
          routing: %{atom() => module()},
          accepted_versions: [String.t()],
          per_project: %{String.t() => per_project_state()}
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

  @doc """
  Route a transition to a provider.

  Canonical per-project routing uses `{project_id, database_path}` as the
  routing key. Legacy global routing by provider atom remains supported for
  callers that still pass `:beads`-style provider identifiers.
  """
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
          | {:error, :contract_version_mismatch | :invalid_module}
  def register(provider_module) when is_atom(provider_module) do
    GenServer.call(__MODULE__, {:register, provider_module})
  end

  def register(_provider_module), do: {:error, :invalid_module}

  @spec register_for_project(String.t(), module(), map()) ::
          :ok
          | {:error,
             :contract_version_mismatch | :invalid_module | :invalid_project_id | :unavailable}
  def register_for_project(project_id, provider_module, config) do
    GenServer.call(__MODULE__, {:register_for_project, project_id, provider_module, config})
  end

  @spec unregister_for_project(String.t(), atom()) :: :ok | {:error, :not_found}
  def unregister_for_project(project_id, reason) do
    GenServer.call(__MODULE__, {:unregister_for_project, project_id, reason})
  end

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

    {:ok, %{routing: routing, accepted_versions: accepted_versions, per_project: %{}}}
  end

  @impl true
  def handle_call(:routing_snapshot, _from, state) do
    project_entries =
      state.per_project
      |> Map.filter(fn {_id, entry} -> match?({:active, _}, entry) end)
      |> Map.new(fn {project_id, {:active, %{provider_module: pm}}} -> {project_id, pm} end)

    {:reply, Map.merge(state.routing, project_entries), state}
  end

  def handle_call({:register, provider_module}, _from, state) do
    case register_global_provider(provider_module, state.routing, state.accepted_versions) do
      {:ok, _provider_id, routing} ->
        {:reply, {:ok, provider_module}, %{state | routing: routing}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:register_for_project, project_id, provider_module, config}, _from, state) do
    case register_project_provider(project_id, provider_module, config, state) do
      {:ok, per_project} ->
        TaskProviderTelemetry.emit(@per_project_register_event_prefix ++ [:ok], %{count: 1}, %{
          project_id: project_id,
          provider: provider_module
        })

        {:reply, :ok, %{state | per_project: per_project}}

      {:error, reason} = error ->
        TaskProviderTelemetry.emit(@per_project_register_event_prefix ++ [:error], %{count: 1}, %{
          project_id: project_id,
          provider: provider_module,
          reason: reason
        })

        {:reply, error, state}
    end
  end

  def handle_call({:unregister_for_project, project_id, reason}, _from, state) do
    per_project = Map.put(state.per_project, project_id, {:unavailable, reason})

    TaskProviderTelemetry.emit(@per_project_unregister_event, %{count: 1}, %{
      project_id: project_id,
      reason: reason
    })

    {:reply, :ok, %{state | per_project: per_project}}
  end

  def handle_call({:route, transition, routing_key}, _from, state) do
    reply = route_provider(state, transition, routing_key)
    emit_route_telemetry(reply, transition, routing_key)
    {:reply, reply, state}
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
      case register_global_provider(provider_module, routing, accepted_versions) do
        {:ok, _provider_id, new_routing} ->
          new_routing

        {:error, reason} ->
          Logger.warning("skipping task provider #{inspect(provider_module)}: #{inspect(reason)}")
          routing
      end
    end)
  end

  defp register_global_provider(provider_module, routing, accepted_versions) do
    with :ok <- ensure_provider_module(provider_module),
         capabilities <- provider_module.capabilities(),
         :ok <- ensure_contract_version(capabilities, accepted_versions) do
      provider_id = provider_id(provider_module, capabilities)
      {:ok, provider_id, Map.put(routing, provider_id, provider_module)}
    end
  end

  defp register_project_provider(project_id, provider_module, config, state) do
    with :ok <- ensure_project_id(project_id),
         :ok <- ensure_project_config(config),
         {:ok, _provider_id, _routing} <-
           register_global_provider(provider_module, state.routing, state.accepted_versions),
         :ok <- ensure_available(provider_module) do
      {:ok,
       Map.put(
         state.per_project,
         project_id,
         {:active, %{provider_module: provider_module, config: config}}
       )}
    end
  end

  defp ensure_project_id(project_id) when is_binary(project_id) and project_id != "", do: :ok
  defp ensure_project_id(_project_id), do: {:error, :invalid_project_id}

  defp ensure_project_config(config) when is_map(config), do: :ok
  defp ensure_project_config(_config), do: {:error, :invalid_module}

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

  defp route_provider(state, transition, {project_id, database_path})
       when is_binary(project_id) do
    case Map.fetch(state.per_project, project_id) do
      {:ok, {:active, %{provider_module: provider_module, config: config}}} ->
        cond do
          project_database_path(config) != database_path ->
            {:error, :database_path_mismatch}

          not supports_transition?(provider_module, transition) ->
            {:error, :no_provider_for_transition}

          true ->
            {:ok, provider_module}
        end

      {:ok, {:unavailable, _reason}} ->
        {:error, :provider_unavailable_for_project}

      :error ->
        {:error, :task_provider_not_configured}
    end
  end

  defp route_provider(state, transition, routing_key) do
    route_global_provider(state.routing, transition, routing_key)
  end

  defp route_global_provider(routing, transition, routing_key) do
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

  defp project_database_path(config) when is_map(config) do
    Map.get(config, :database_path) || Map.get(config, "database_path")
  end

  defp project_database_path(_config), do: nil

  defp emit_route_telemetry(result, transition, routing_key) do
    case result do
      {:ok, provider_module} ->
        TaskProviderTelemetry.emit(@route_event_prefix ++ [:ok], %{count: 1}, %{
          transition: transition,
          routing_key: telemetry_routing_key(routing_key),
          provider: provider_module
        })

      {:error, reason} ->
        TaskProviderTelemetry.emit(@route_event_prefix ++ [:error], %{count: 1}, %{
          transition: transition,
          routing_key: telemetry_routing_key(routing_key),
          reason: reason
        })
    end
  end

  defp telemetry_routing_key({project_id, database_path}) when is_binary(database_path) do
    {project_id, "/abs/<redacted:#{String.length(database_path)}>"}
  end

  defp telemetry_routing_key(routing_key), do: routing_key

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
