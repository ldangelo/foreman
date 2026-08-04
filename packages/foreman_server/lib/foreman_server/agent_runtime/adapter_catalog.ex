defmodule ForemanServer.AgentRuntime.AdapterCatalog do
  @moduledoc """
  GenServer managing backend adapter registration and snapshots.
  """

  use GenServer
  alias ForemanServer.AgentRuntime.BackendAdapter
  alias ForemanServer.Telemetry

  @registry_name ForemanServer.AgentRuntime.AdapterRegistry

  @type state :: %{adapters: [module()], snapshots: map(), seq: non_neg_integer()}

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec register(module(), GenServer.server()) :: {:ok, module()} | {:error, term()}
  def register(module, server \\ __MODULE__), do: GenServer.call(server, {:register, module})

  @spec unregister(module(), GenServer.server()) :: :ok | {:error, :not_found}
  def unregister(module, server \\ __MODULE__), do: GenServer.call(server, {:unregister, module})

  @spec snapshot(GenServer.server()) :: [module()]
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  def empty?(server \\ __MODULE__), do: GenServer.call(server, :empty)

  @spec available?(module(), GenServer.server()) :: boolean()
  def available?(module, server \\ __MODULE__), do: GenServer.call(server, {:available, module})

  @spec lookup(backend_name :: atom(), GenServer.server()) :: {:ok, module()} | {:error, :not_found}
  def lookup(backend_name, server \\ __MODULE__), do: GenServer.call(server, {:lookup, backend_name})

  @impl true
  def init(opts) do
    Registry.start_link(keys: :unique, name: @registry_name)
    adapters = Keyword.get(opts, :adapters, [])
    state = %{adapters: [], snapshots: %{}, seq: 0}

    state = Enum.reduce(adapters, state, fn adapter_mod, acc_state ->
      case register_adapter(adapter_mod, acc_state, startup: true) do
        {:ok, new_state, _name} -> new_state
        {:error, reason} -> raise "Invalid adapter #{inspect(adapter_mod)}: #{inspect(reason)}"
      end
    end)

    {:ok, state}
  end

  defp register_adapter(module, state, opts \\ []) do
    case BackendAdapter.validate_capabilities(module) do
      {:ok, validated_caps} ->
        name = module.name()
        available = apply(module, :available?, [])
        already_registered? = module in state.adapters

        new_adapters = if already_registered?, do: state.adapters, else: state.adapters ++ [module]
        new_snapshots = Map.put(state.snapshots, module, %{name: name, capabilities: validated_caps, available: available})
        new_state = %{state | adapters: new_adapters, snapshots: new_snapshots, seq: state.seq + 1}

        Registry.register(@registry_name, name, module)

        unless Keyword.get(opts, :startup, false) do
          Telemetry.execute([:foreman, :agent_runtime, :catalog, :register], %{system_time: System.system_time()}, %{backend: name})
        end

        {:ok, new_state, name}
      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def handle_call({:register, module}, _from, state) do
    case register_adapter(module, state) do
      {:ok, new_state, _name} -> {:reply, {:ok, module}, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:unregister, module}, _from, state) do
    if module in state.adapters do
      name = module.name()
      new_adapters = List.delete(state.adapters, module)
      new_snapshots = Map.delete(state.snapshots, module)
      new_state = %{state | adapters: new_adapters, snapshots: new_snapshots, seq: state.seq + 1}
      Registry.unregister(@registry_name, name)
      Telemetry.execute([:foreman, :agent_runtime, :catalog, :unregister], %{system_time: System.system_time()}, %{backend: name})
      {:reply, :ok, new_state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.adapters, state}

  @impl true
  def handle_call(:empty, _from, state), do: {:reply, state.adapters == [], state}
  def handle_call({:lookup, backend_name}, _from, state) do
    case Registry.lookup(@registry_name, backend_name) do
      [{_pid, module}] -> {:reply, {:ok, module}, state}
      [] -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:available, module}, _from, state) do
    result = case Map.fetch(state.snapshots, module) do
      {:ok, snapshot} -> snapshot.available
      :error -> false
    end
    {:reply, result, state}
  end
end
