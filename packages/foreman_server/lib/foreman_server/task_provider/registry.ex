defmodule ForemanServer.TaskProvider.Registry do
  @moduledoc """
  In-memory registry of `ForemanServer.TaskProvider` implementations.

  Loads configured providers at boot and exposes an atomic routing snapshot for
  the dispatch path.

  Every provider is admitted through one provider-generic contract
  (`validate_capabilities/1`): `capabilities/0` must be a map carrying
  `provider_id`, `contract_version`, `supports` and `storage_scheme` at the right
  types. A provider whose map breaks it is left out of the routing snapshot and
  reported on `[:foreman_server, :task_provider, :registry, :invalid_capabilities]`;
  nothing in the registry recognises a provider by name.

  Restart strategy: `:permanent` (must be supervised with `restart: :permanent`).
  Emits `[:foreman_server, :task_provider, :registry, :restarted]` on each
  restart after the initial boot.
  """

  use GenServer

  alias ForemanServer.TaskProvider
  alias ForemanServer.TaskProvider.StorageBinding
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
  @invalid_capabilities_event [:foreman_server, :task_provider, :registry, :invalid_capabilities]
  @required_capability_keys [:provider_id, :contract_version, :supports, :storage_scheme]
  @required_callbacks TaskProvider.behaviour_info(:callbacks)

  @type per_project_state ::
          {:active, %{provider_module: module(), config: map()}}
          | {:unavailable, atom()}
  @type state :: %{
          routing: %{atom() => module()},
          accepted_versions: [String.t()],
          per_project: %{String.t() => per_project_state()}
        }

  @typedoc "One way a `capabilities/0` map breaks the provider contract; names the key, never the value."
  @type violation :: :not_a_map | {:missing_key, atom()} | {:invalid_value, atom()}

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

  Canonical per-project routing uses `{project_id, binding}` as the routing key, where
  `binding` is the project's value for the config key its provider's storage scheme names
  (`database_path` for `:sqlite`, `cwd` for `:cli_process`; see
  `ForemanServer.TaskProvider.StorageBinding`). A binding that differs from the registered
  one is `:database_path_mismatch` or `:cwd_mismatch` accordingly. Legacy global routing by
  provider atom remains supported for callers that still pass `:beads`-style provider
  identifiers.
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
          | {:error, :contract_version_mismatch | :invalid_module | :invalid_capabilities}
  def register(provider_module) when is_atom(provider_module) do
    GenServer.call(__MODULE__, {:register, provider_module})
  end

  def register(_provider_module), do: {:error, :invalid_module}

  @spec register_for_project(String.t(), module(), map()) ::
          :ok
          | {:error,
             :contract_version_mismatch
             | :invalid_module
             | :invalid_capabilities
             | :invalid_project_id
             | :unavailable}
  def register_for_project(project_id, provider_module, config) do
    GenServer.call(__MODULE__, {:register_for_project, project_id, provider_module, config})
  end

  @spec project_config(project_id :: String.t()) ::
          {:ok, %{provider_module: module(), config: map()}} | {:error, atom()}
  def project_config(project_id) when is_binary(project_id) do
    GenServer.call(__MODULE__, {:project_config, project_id})
  end

  def project_config(_project_id), do: {:error, :invalid_project_id}

  @spec unregister_for_project(String.t(), atom()) :: :ok | {:error, :not_found}
  def unregister_for_project(project_id, reason) do
    GenServer.call(__MODULE__, {:unregister_for_project, project_id, reason})
  end

  @doc """
  Checks a `capabilities/0` map against the contract every provider shares.

  Required: `provider_id` (an atom), `contract_version` (a non-empty string), `supports` (a list
  of atoms) and `storage_scheme` (one of `ForemanServer.TaskProvider.StorageBinding.schemes/0`).
  `id_format` is optional and, when present, must be a pattern that compiles. Unknown keys are
  ignored.

  Returns every violation, required keys first in declaration order, so a map that breaks several
  rules is diagnosed in one pass.
  """
  @spec validate_capabilities(term()) :: :ok | {:error, [violation(), ...]}
  def validate_capabilities(capabilities) when is_map(capabilities) do
    case capability_violations(capabilities) do
      [] -> :ok
      violations -> {:error, violations}
    end
  end

  def validate_capabilities(_capabilities), do: {:error, [:not_a_map]}

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

  def handle_call(:reload_config, _from, _state) do
    {accepted_versions, providers} = provider_config()
    routing = load_providers(providers, accepted_versions)

    {:reply, :ok, %{routing: routing, accepted_versions: accepted_versions, per_project: %{}}}
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

  def handle_call({:project_config, project_id}, _from, state) do
    reply = resolve_project_config(state.per_project, project_id)
    {:reply, reply, state}
  end

  def handle_call({:route, transition, routing_key}, _from, state) do
    reply = route_provider(state, transition, routing_key)
    emit_route_telemetry(reply, transition, routing_key)
    {:reply, reply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  ## Internal

  defp resolve_project_config(per_project, project_id) do
    case Map.fetch(per_project, project_id) do
      {:ok, {:active, %{provider_module: provider_module, config: config}}} ->
        {:ok, %{provider_module: provider_module, config: config}}

      {:ok, {:unavailable, _reason}} ->
        {:error, :provider_unavailable_for_project}

      :error ->
        {:error, :task_provider_not_configured}
    end
  end

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
         :ok <- ensure_valid_capabilities(provider_module, capabilities),
         :ok <- ensure_contract_version(capabilities, accepted_versions) do
      {:ok, capabilities.provider_id, Map.put(routing, capabilities.provider_id, provider_module)}
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

  defp ensure_valid_capabilities(provider_module, capabilities) do
    case validate_capabilities(capabilities) do
      :ok ->
        :ok

      {:error, violations} ->
        Logger.warning(
          "rejecting task provider #{inspect(provider_module)}: invalid capabilities " <>
            inspect(violations)
        )

        TaskProviderTelemetry.emit(@invalid_capabilities_event, %{count: 1}, %{
          provider: provider_module,
          violations: violations
        })

        {:error, :invalid_capabilities}
    end
  end

  defp capability_violations(capabilities) do
    required = Enum.flat_map(@required_capability_keys, &required_violation(capabilities, &1))
    required ++ optional_violation(capabilities, :id_format)
  end

  defp required_violation(capabilities, key) do
    case Map.fetch(capabilities, key) do
      {:ok, value} -> invalid_value(key, value)
      :error -> [{:missing_key, key}]
    end
  end

  defp optional_violation(capabilities, key) do
    case Map.fetch(capabilities, key) do
      {:ok, value} -> invalid_value(key, value)
      :error -> []
    end
  end

  defp invalid_value(key, value) do
    if valid_capability_value?(key, value), do: [], else: [{:invalid_value, key}]
  end

  defp valid_capability_value?(:provider_id, value),
    do: is_atom(value) and value not in [nil, true, false]

  defp valid_capability_value?(:contract_version, value), do: is_binary(value) and value != ""
  defp valid_capability_value?(:supports, value), do: atom_list?(value)
  defp valid_capability_value?(:storage_scheme, value), do: value in StorageBinding.schemes()

  defp valid_capability_value?(:id_format, value),
    do: is_binary(value) and match?({:ok, _regex}, Regex.compile(value))

  defp atom_list?([]), do: true
  defp atom_list?([head | tail]) when is_atom(head), do: atom_list?(tail)
  defp atom_list?(_other), do: false

  defp ensure_available(provider_module) do
    case provider_module.available?() do
      true -> :ok
      false -> {:error, :unavailable}
    end
  end

  defp route_provider(state, transition, {project_id, binding}) when is_binary(project_id) do
    case Map.fetch(state.per_project, project_id) do
      {:ok, {:active, %{provider_module: provider_module, config: config}}} ->
        cond do
          registered_binding(provider_module, config) != binding ->
            {:error, binding_mismatch_reason(provider_module)}

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

  defp route_provider(state, :create, %{project_id: project_id}) when is_binary(project_id) do
    case Map.fetch(state.per_project, project_id) do
      {:ok, {:active, %{provider_module: provider_module, config: _config}}} ->
        if supports_transition?(provider_module, :create) do
          {:ok, provider_module}
        else
          {:error, :capability_not_supported}
        end

      {:ok, {:unavailable, _reason}} ->
        {:error, :provider_unavailable_for_project}

      :error ->
        {:error, :no_provider}
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

  # The value the project's config holds under the key its provider's storage scheme names
  # (`StorageBinding`); `nil` when it holds none.
  defp registered_binding(provider_module, config) do
    case StorageBinding.fetch(provider_module, config) do
      {:ok, binding} -> binding
      {:error, _reason} -> nil
    end
  end

  defp binding_mismatch_reason(provider_module) do
    case StorageBinding.scheme(provider_module) do
      {:ok, scheme} -> StorageBinding.mismatch_reason(scheme)
      {:error, :invalid_capabilities} -> :invalid_capabilities
    end
  end

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

  defp telemetry_routing_key({project_id, binding}) when is_binary(binding) do
    {project_id, "/abs/<redacted:#{String.length(binding)}>"}
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
