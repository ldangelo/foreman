defmodule ForemanServer.AgentRuntime.Router do
  @moduledoc """
  Pure routing selectors for AgentRuntime strategies.

  Provides manual routing (by backend name), deterministic automatic routing
  via `Router.automatic/2` (capability-filtered, available, stable tiebreak on
  cost → latency → registration order), and a stub for policy routing
  (TRD-006).
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
  Automatic routing candidates: return an ordered list of candidates based on
  task capabilities.

  Filters adapters by:
  1. supported_contexts contains opts[:task_type]
  2. available

  Sorts by: cost_per_call (asc), typical_latency_ms (asc), registration_index (asc)

  Missing optional numeric values sort after declared values.
  Returns `{:ok, [{adapter, available?}, ...]}` or `{:error, :no_available_backend}`.

  Per TRD-008 AC-004-2: returns only available backends in the candidate list.
  """
  @spec automatic_candidates(map(), keyword()) ::
          {:ok, [candidate()]} | {:error, :no_available_backend}
  def automatic_candidates(_request, opts \\ []) do
    catalog = Keyword.get(opts, :catalog, AdapterCatalog)
    task_type = Keyword.get(opts, :task_type)

    if is_nil(task_type) do
      {:error, :no_available_backend}
    else
      snapshot = AdapterCatalog.routing_snapshot(catalog)

      ranked =
        snapshot
        |> Enum.filter(fn entry ->
          supported = Map.get(entry.capabilities, :supported_contexts, [])
          is_list(supported) and task_type in supported
        end)
        |> Enum.filter(fn entry -> entry.available end)
        |> Enum.with_index()
        |> Enum.sort_by(fn {entry, index} ->
          cost = Map.get(entry.capabilities, :cost_per_call)
          latency = Map.get(entry.capabilities, :typical_latency_ms)
          {{is_nil(cost), cost || 0}, {is_nil(latency), latency || 0}, index}
        end)

      case ranked do
        [] -> {:error, :no_available_backend}
        _ -> {:ok, Enum.map(ranked, fn {entry, _} -> {entry.adapter, true} end)}
      end
    end
  end

  @doc """
  Automatic routing: select a single adapter based on task capabilities.

  Uses `automatic_candidates/2` internally and returns the first candidate.
  Returns `{:ok, adapter_module}` or `{:error, :no_available_backend}`.
  """
  @spec automatic(map(), keyword()) :: {:ok, adapter()} | {:error, :no_available_backend}
  def automatic(request, opts \\ []) do
    case automatic_candidates(request, opts) do
      {:ok, []} -> {:error, :no_available_backend}
      {:ok, [{adapter, _} | _]} -> {:ok, adapter}
      {:error, _} = err -> err
    end
  end

  @typedoc """
  A single routing candidate. The Invocation layer (TRD-008) iterates the
  ordered candidate list returned by `Router.policy/3` and decides whether
  to skip a candidate based on its availability and the resolved failure
  policy.
  """
  @type candidate :: {adapter(), boolean()}

  @doc """
  Policy-based routing: delegate the backend choice to a configured policy
  module and return an ordered candidate list.

  The list is built in two steps:

    1. The policy module receives the routing snapshot's capabilities
       keyed by backend name and returns the backend it has selected.
       That selection is preserved as the first candidate — including when
       it is unavailable or task-type-mismatched — so the Invocation
       layer can decide whether to skip it per the resolved failure
       policy (TRD-007 / TRD-008).
    2. The remaining catalog entries are ranked by the same rules
       `Router.automatic/2` uses (supported-contexts → available → cost
       → latency → registration order) and follow the policy's selection.

  Returns `{:ok, candidates}` where the first tuple is always the
  policy's registered choice (with its actual availability flag) and
  the remainder are auto-ranked available fallbacks. Returns
  `{:error, :backend_not_found}` when the policy names a backend that
  is not registered. Returns `{:error, :no_available_backend}` when the
  catalog is empty, the policy module is missing, or the policy module
  does not export `route/2`.

  ## Options

    * `:catalog` — defaults to `AdapterCatalog`; the catalog to read the
      point-in-time routing snapshot from.
    * `:task_type` — the atom passed to the policy module and used to
      filter the auto-ranked fallbacks.

  `:backend` is intentionally NOT accepted: the policy module owns the
  selection and the caller must not override it.
  """
  @spec policy(map(), keyword(), module() | nil) ::
          {:ok, [candidate()]}
          | {:error,
             :backend_not_found | :no_available_backend | {:policy_module_raised, atom(), term()}}
  def policy(_request, opts, policy_module) do
    catalog = Keyword.get(opts, :catalog, AdapterCatalog)
    task_type = Keyword.get(opts, :task_type)

    cond do
      is_nil(policy_module) ->
        {:error, :no_available_backend}

      not valid_policy_module?(policy_module) ->
        {:error, :no_available_backend}

      true ->
        snapshot = AdapterCatalog.routing_snapshot(catalog)

        if snapshot == [] do
          {:error, :no_available_backend}
        else
          capabilities_map = Map.new(snapshot, &{&1.name, &1.capabilities})

          chosen_name =
            try do
              policy_module.route(task_type, capabilities_map)
            catch
              kind, reason -> {:error, {:policy_module_raised, kind, reason}}
            end

          case chosen_name do
            {:error, _} = error ->
              error

            name ->
              case Enum.find(snapshot, &(&1.name == name)) do
                nil ->
                  {:error, :backend_not_found}

                chosen_entry ->
                  primary = {chosen_entry.adapter, chosen_entry.available}
                  fallbacks = auto_ranked_fallbacks(snapshot, task_type, chosen_entry.adapter)
                  {:ok, [primary | fallbacks]}
              end
          end
        end
    end
  end

  defp auto_ranked_fallbacks(snapshot, task_type, exclude_adapter) do
    if is_nil(task_type) do
      []
    else
      indexed =
        snapshot
        |> Enum.reject(fn entry -> entry.adapter == exclude_adapter end)
        |> Enum.filter(fn entry -> entry.available end)
        |> Enum.filter(fn entry ->
          supported = Map.get(entry.capabilities, :supported_contexts, [])
          is_list(supported) and task_type in supported
        end)
        |> Enum.with_index()

      sorted =
        Enum.sort_by(indexed, fn {entry, index} ->
          cost = Map.get(entry.capabilities, :cost_per_call)
          latency = Map.get(entry.capabilities, :typical_latency_ms)
          {{is_nil(cost), cost || 0}, {is_nil(latency), latency || 0}, index}
        end)

      Enum.map(sorted, fn {entry, _index} -> {entry.adapter, true} end)
    end
  end

  defp valid_policy_module?(policy_module) do
    Code.ensure_loaded?(policy_module) and function_exported?(policy_module, :route, 2)
  end
end
