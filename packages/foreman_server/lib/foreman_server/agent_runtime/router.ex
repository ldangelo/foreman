defmodule ForemanServer.AgentRuntime.Router do
  @moduledoc """
  Pure routing selectors for AgentRuntime strategies.

  Provides manual routing (by backend name), deterministic automatic routing
  via `Router.automatic/2` (capability-filtered, available, stable tiebreak on
  cost → latency → registration order), and a stub for policy routing
  (TRD-006).
  """

  alias ForemanServer.AgentRuntime.AdapterCatalog
  alias ForemanServer.AgentRuntime.BackendAdapter
  @type backend_name :: atom()
  @type adapter :: module()

  @doc """
  Manual routing: look up a backend by name and verify availability.

  Returns `{:ok, adapter_module}` if found and available.
  Returns `{:error, :backend_not_found}` if the name is not registered.
  Returns `{:error, :backend_unavailable}` if registered but not available.
  """
  @spec manual(backend_name(), keyword()) ::
          {:ok, adapter()}
          | {:error, :backend_not_found | :backend_unavailable | :no_available_backend}
  def manual(backend_name, opts \\ []) do
    catalog = Keyword.get(opts, :catalog, AdapterCatalog)
    check_availability = Keyword.get(opts, :check_availability, true)

    # Check if catalog is empty first - TRD-003 AC
    if AdapterCatalog.empty?(catalog) do
      {:error, :no_available_backend}
    else
      case AdapterCatalog.lookup(backend_name, catalog) do
        {:ok, adapter_module} ->
          if check_availability && !AdapterCatalog.available?(adapter_module, catalog) do
            {:error, :backend_unavailable}
          else
            {:ok, adapter_module}
          end

        {:error, :not_found} ->
          {:error, :backend_not_found}
      end
    end
  end

  @doc """
  Automatic routing: select an adapter based on task capabilities.

  Filters adapters by:
  1. supported_contexts contains opts[:task_type]
  2. available? returns true
  3. Sorts by: cost_per_call (asc), typical_latency_ms (asc), registration_index (asc)

  Missing optional numeric values sort after declared values.
  Returns first match or {:error, :no_available_backend}.
  """
  @spec automatic(map(), keyword()) :: {:ok, adapter()} | {:error, :no_available_backend}
  def automatic(_request, opts \\ []) do
    catalog = Keyword.get(opts, :catalog, AdapterCatalog)
    task_type = Keyword.get(opts, :task_type)

    # If no task_type provided, no adapter can be selected
    if is_nil(task_type) do
      {:error, :no_available_backend}
    else
      # Get all registered adapters in stable registration order
      all_adapters = AdapterCatalog.snapshot(catalog)

      # Filter: supported_contexts contains task_type
      matching_context =
        Enum.filter(all_adapters, fn adapter ->
          case BackendAdapter.validate_capabilities(adapter) do
            {:ok, %{supported_contexts: contexts}} when is_list(contexts) ->
              task_type in contexts

            _ ->
              false
          end
        end)

      # Filter: available
      available =
        Enum.filter(matching_context, fn adapter ->
          AdapterCatalog.available?(adapter, catalog)
        end)

      # Build list of {adapter_module, registration_index, cost_per_call, typical_latency_ms}
      # Missing optional values (nil) sort after declared values using tuple comparison:
      # {{cost_present?, cost_value}, {latency_present?, latency_value}, registration_index}
      indexed_adapters =
        Enum.with_index(available, fn adapter, index ->
          {:ok, caps} = BackendAdapter.validate_capabilities(adapter)
          cost = Map.get(caps, :cost_per_call)
          latency = Map.get(caps, :typical_latency_ms)
          {adapter, index, cost, latency}
        end)

      # Sort by cost_per_call (declared before missing), then latency (declared before missing), then registration_index
      sorted =
        Enum.sort_by(indexed_adapters, fn {_adapter, index, cost, latency} ->
          {{is_nil(cost), cost || 0}, {is_nil(latency), latency || 0}, index}
        end)

      case sorted do
        [{adapter, _index, _cost, _latency} | _] -> {:ok, adapter}
        [] -> {:error, :no_available_backend}
      end
    end
  end

  @doc """
  Policy-based routing: delegate to a configured policy module.

  Not implemented yet - returns error for now.
  """
  @spec policy(map(), keyword()) :: {:ok, adapter()} | {:error, :no_available_backend}
  def policy(_request, _opts \\ []) do
    {:error, :not_implemented}
  end
end
