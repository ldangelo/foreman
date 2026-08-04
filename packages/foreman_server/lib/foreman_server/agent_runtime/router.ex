defmodule ForemanServer.AgentRuntime.Router do
  @moduledoc """
  Pure routing selectors for AgentRuntime strategies.

  Provides manual routing (by backend name) and stubs for automatic/policy
  routing (implemented in future TRDs).
  """

  alias ForemanServer.AgentRuntime.AdapterCatalog

  @type backend_name :: atom()
  @type adapter :: module()

  @doc """
  Manual routing: look up a backend by name and verify availability.

  Returns `{:ok, adapter_module}` if found and available.
  Returns `{:error, :backend_not_found}` if the name is not registered.
  Returns `{:error, :backend_unavailable}` if registered but not available.
  """
  @spec manual(backend_name(), keyword()) ::
          {:ok, adapter()} | {:error, :backend_not_found | :backend_unavailable | :no_available_backend}
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

  Not implemented yet - returns error for now.
  """
  @spec automatic(map(), keyword()) :: {:ok, adapter()} | {:error, :no_available_backend}
  def automatic(_request, _opts \\ []) do
    {:error, :not_implemented}
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
