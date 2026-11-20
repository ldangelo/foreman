defmodule ForemanServer.TaskProvider.StorageBinding do
  @moduledoc """
  How a project is bound to its task provider's storage, keyed on the provider's declared
  `capabilities[:storage_scheme]` and on nothing else.

  | scheme          | the provider                                 | project config key | preflight                             |
  | --------------- | -------------------------------------------- | ------------------ | ------------------------------------- |
  | `:sqlite`       | is backed by a database file                 | `:database_path`   | the provider's `preflight_database/2` |
  | `:cli_process`  | shells out to a CLI that resolves its storage | `:cwd`            | an absolute, existing directory       |

  The registry (routing key and mismatch reason), the projector (preflight) and the run executor
  (routing key) read the key through `fetch/2`, and `resolve_update/2` applies the same rule to a
  `project.update`. No caller recognises a provider by name, and a new scheme is a one-place change.
  """

  alias ForemanServer.Aggregate

  @type scheme :: :sqlite | :cli_process
  @type key :: :database_path | :cwd
  @type task_provider :: map()

  @schemes [:sqlite, :cli_process]

  @doc "The closed set of storage schemes a capability map may declare."
  @spec schemes() :: [scheme(), ...]
  def schemes, do: @schemes

  @doc "The project config key that binds a project to storage of this scheme."
  @spec key(scheme()) :: key()
  def key(:sqlite), do: :database_path
  def key(:cli_process), do: :cwd

  @doc "The routing error for a caller whose binding differs from the registered one."
  @spec mismatch_reason(scheme()) :: :database_path_mismatch | :cwd_mismatch
  def mismatch_reason(:sqlite), do: :database_path_mismatch
  def mismatch_reason(:cli_process), do: :cwd_mismatch

  @doc """
  The storage scheme `provider_module` declares, or `:invalid_capabilities` when it declares none
  the registry accepts.
  """
  @spec scheme(module()) :: {:ok, scheme()} | {:error, :invalid_capabilities}
  def scheme(provider_module) when is_atom(provider_module) do
    case provider_module.capabilities() do
      %{storage_scheme: scheme} when scheme in @schemes -> {:ok, scheme}
      _other -> {:error, :invalid_capabilities}
    end
  end

  @doc """
  The binding value in a project's `config`: a non-empty string under the scheme's key.

  Both key conventions reach this boundary (in-process commands carry atom keys, JSON ingress
  carries strings, and the stored config keeps whichever arrived), so this is the one place that
  reads either. An absent or blank value is `{:missing_binding_key, key}`.
  """
  @spec fetch(module(), term()) ::
          {:ok, String.t()} | {:error, {:missing_binding_key, key()} | :invalid_capabilities}
  def fetch(provider_module, config) do
    with {:ok, scheme} <- scheme(provider_module) do
      key = key(scheme)

      case read(config, key) do
        value when is_binary(value) and value != "" -> {:ok, value}
        _absent_or_blank -> {:error, {:missing_binding_key, key}}
      end
    end
  end

  @doc """
  The `task_provider` a `project.update` must store, given the one stored today (`nil` when there
  is none) and the one the update asks for.

    * The same provider and no `config` in the request: the stored `config` is kept. An update
      that only restates the provider (all the CLI sends) must not unbind the project.
    * A different provider, or none stored yet, whose scheme is known: the request's `config` must
      carry the scheme's key, otherwise `{:missing_or_invalid, key}` names it. No value is derived
      or defaulted.
    * Anything else is stored as asked; a request that carries a `config` replaces the stored block
      atomically.
  """
  @spec resolve_update(task_provider() | nil, task_provider()) ::
          {:ok, task_provider()} | {:error, {:missing_or_invalid, key()}}
  def resolve_update(stored, requested) do
    ref = Aggregate.get(requested, :provider)

    if identity(Aggregate.get(stored, :provider)) == identity(ref) do
      keep_stored_config(stored, requested)
    else
      require_binding(ref, requested)
    end
  end

  @doc """
  The configured provider module a `task_provider.provider` reference names: a module that exports
  `capabilities/0`, a full module name, or a provider id (`:beads`, `"beads"`). References are
  compared as strings against the configured providers, so no atom is ever created from input.
  """
  @spec provider_for_ref(term()) :: {:ok, module()} | :error
  def provider_for_ref(ref) when is_atom(ref) and not is_nil(ref) do
    if provider_module?(ref), do: {:ok, ref}, else: find_configured(Atom.to_string(ref))
  end

  def provider_for_ref(ref) when is_binary(ref), do: find_configured(ref)
  def provider_for_ref(_ref), do: :error

  defp keep_stored_config(stored, requested) do
    case {Aggregate.get(requested, :config), Aggregate.get(stored, :config)} do
      {nil, stored_config} when is_map(stored_config) ->
        {:ok, put_config(requested, stored_config)}

      {_requested_config, _stored_config} ->
        {:ok, requested}
    end
  end

  defp require_binding(ref, requested) do
    case provider_for_ref(ref) do
      {:ok, provider_module} ->
        case fetch(provider_module, Aggregate.get(requested, :config)) do
          {:ok, _binding} -> {:ok, requested}
          {:error, {:missing_binding_key, key}} -> {:error, {:missing_or_invalid, key}}
          # A provider that declares no usable scheme is refused by the registry when it is
          # registered; which key to demand is not this module's call.
          {:error, :invalid_capabilities} -> {:ok, requested}
        end

      # An unknown provider cannot be asked what it needs; the projector reports it unroutable.
      :error ->
        {:ok, requested}
    end
  end

  defp put_config(%{"provider" => _} = requested, config),
    do: Map.put(requested, "config", config)

  defp put_config(requested, config), do: Map.put(requested, :config, config)

  # Two references name the same provider when they resolve to the same module; an unknown
  # provider is compared by name.
  defp identity(ref) do
    case provider_for_ref(ref) do
      {:ok, provider_module} -> provider_module
      :error when is_atom(ref) and not is_nil(ref) -> Atom.to_string(ref)
      :error -> ref
    end
  end

  defp find_configured(ref_string) do
    Enum.find_value(configured_providers(), :error, fn provider_module ->
      if provider_module?(provider_module) and ref_string in names(provider_module),
        do: {:ok, provider_module}
    end)
  end

  defp names(provider_module) do
    provider_ids =
      case provider_module.capabilities() do
        %{provider_id: id} when is_atom(id) and not is_nil(id) -> [Atom.to_string(id)]
        _other -> []
      end

    [inspect(provider_module), Atom.to_string(provider_module) | provider_ids]
  end

  defp provider_module?(provider_module) when is_atom(provider_module) do
    Code.ensure_loaded?(provider_module) and function_exported?(provider_module, :capabilities, 0)
  end

  defp provider_module?(_provider_module), do: false

  defp configured_providers do
    :foreman_server |> Application.get_env(:task_provider, []) |> Keyword.get(:providers, [])
  end

  defp read(config, key) when is_map(config), do: Aggregate.get(config, key)
  defp read(_config, _key), do: nil
end
