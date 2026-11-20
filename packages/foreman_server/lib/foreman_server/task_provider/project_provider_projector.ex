defmodule ForemanServer.TaskProvider.ProjectProviderProjector do
  @moduledoc """
  Subscribes to ProjectionStore events and projects `task_provider` config
  blocks into the Registry's per-project routing state.

  Per-project registration flow:

    * `ProjectRegistered` with `task_provider` and successful preflight
      registers the provider for that project.
    * `ProjectRegistered` without `task_provider` does nothing.
    * `ProjectUpdated` with `task_provider` re-registers the provider.
    * `ProjectUpdated` without `task_provider` preserves the existing routing.
    * Preflight follows the provider's declared storage scheme
      (`ForemanServer.TaskProvider.StorageBinding`): a `:sqlite` provider is verified through its
      own `preflight_database/2`, a `:cli_process` provider needs an absolute, existing `cwd`.
      Failures unregister the project with a concrete reason such as `:database_not_found`,
      `:cwd_not_found`, `:cwd_not_absolute` or `:cwd_missing`.
  """

  use GenServer

  alias EventStore.{EventData, RecordedEvent}
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TaskProvider.Registry, as: TaskProviderRegistry
  alias ForemanServer.TaskProvider.StorageBinding
  alias ForemanServer.TaskProviders.ProviderError
  alias ForemanServer.TaskProviders.BeadsOrphanJanitorSupervisor
  alias ForemanServer.TaskProviders.BeadsWatcherSupervisor

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
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

  @impl true
  def init(_opts) do
    case ProjectionStore.subscribe() do
      :ok ->
        rehydrate_from_projection_store()
        {:ok, %{subscription: :subscribed}}

      _other ->
        Process.send_after(self(), :retry_subscribe, 50)
        {:ok, %{subscription: :retrying}}
    end
  end

  def rehydrate_from_projection_store(projects \\ nil) do
    list =
      if projects == nil do
        ProjectionStore.list_projects()
      else
        projects
      end

    Enum.each(list, fn project ->
      payload = %{
        project_id: Map.get(project, :project_id),
        task_provider: Map.get(project, :task_provider)
      }

      process_event(%{event_type: "ProjectRegistered", payload: payload})
    end)
  end

  @impl true
  def handle_info(:retry_subscribe, state) do
    case ProjectionStore.subscribe() do
      :ok ->
        rehydrate_from_projection_store()
        {:noreply, %{state | subscription: :subscribed}}

      _other ->
        Process.send_after(self(), :retry_subscribe, 50)
        {:noreply, state}
    end
  end

  def handle_info({:projection_event, event}, state) do
    process_event(event)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc """
  Process a single ProjectionStore event. Idempotent and unit-testable.

  Accepts the live broadcast shape (`%EventData{}` or `%RecordedEvent{}`,
  payload in `data`) and the test-fixture shape (`%{event_type:, payload:}`).
  Both string- and atom-keyed maps are supported.
  """
  @spec process_event(map() | struct()) :: :ok
  def process_event(%EventData{event_type: "ProjectRegistered", data: data}) do
    process_event(%{event_type: "ProjectRegistered", payload: normalize_event_data(data)})
  end

  def process_event(%EventData{event_type: "ProjectUpdated", data: data}) do
    process_event(%{event_type: "ProjectUpdated", payload: normalize_event_data(data)})
  end

  def process_event(%{"event_type" => "ProjectRegistered", "data" => data}) do
    process_event(%{event_type: "ProjectRegistered", payload: normalize_event_data(data)})
  end

  def process_event(%{"event_type" => "ProjectUpdated", "data" => data}) do
    process_event(%{event_type: "ProjectUpdated", payload: normalize_event_data(data)})
  end

  def process_event(%RecordedEvent{event_type: "ProjectRegistered", data: data}) do
    process_event(%{event_type: "ProjectRegistered", payload: normalize_event_data(data)})
  end

  def process_event(%RecordedEvent{event_type: "ProjectUpdated", data: data}) do
    process_event(%{event_type: "ProjectUpdated", payload: normalize_event_data(data)})
  end

  def process_event(%{event_type: "ProjectRegistered", payload: payload}) do
    handle_project_payload(payload, :register)
  end

  def process_event(%{"event_type" => "ProjectRegistered", "payload" => payload}) do
    handle_project_payload(payload, :register)
  end

  def process_event(%{event_type: "ProjectUpdated", payload: payload}) do
    handle_project_payload(payload, :update)
  end

  def process_event(%{"event_type" => "ProjectUpdated", "payload" => payload}) do
    handle_project_payload(payload, :update)
  end

  def process_event(_other), do: :ok

  defp normalize_event_data(%{} = data), do: data
  defp normalize_event_data(_data), do: %{}

  defp handle_project_payload(payload, mode) do
    project_id = Map.get(payload, :project_id) || Map.get(payload, "project_id")
    task_provider = Map.get(payload, :task_provider) || Map.get(payload, "task_provider")

    case {project_id, task_provider, mode} do
      {project_id, _task_provider, _mode} when not is_binary(project_id) or project_id == "" ->
        :ok

      {_project_id, nil, :register} ->
        :ok

      {_project_id, nil, :update} ->
        :ok

      {project_id, task_provider, _mode} ->
        register_or_unregister_project(project_id, task_provider)
    end
  end

  defp register_or_unregister_project(project_id, task_provider) do
    provider_ref = Map.get(task_provider, :provider) || Map.get(task_provider, "provider")
    config = Map.get(task_provider, :config) || Map.get(task_provider, "config") || %{}

    with {:ok, provider_module} <- resolve_provider_module(provider_ref),
         :ok <- preflight_provider(provider_module, config),
         :ok <- TaskProviderRegistry.register_for_project(project_id, provider_module, config) do
      reconcile_beads_children(project_id, provider_module, config)
      :ok
    else
      {:error, reason} ->
        _ = TaskProviderRegistry.unregister_for_project(project_id, reason)
        stop_project_children(project_id)
        :ok
    end
  end

  # BeadsWatcher / BeadsOrphanJanitor are Beads-only. For other providers we
  # must NOT spawn JSONL workers (they don't speak beads), and we MUST tear
  # down any previously-running Beads children when the project switches away.
  defp reconcile_beads_children(project_id, provider_module, config) do
    with true <- beads_provider?(provider_module),
         {:ok, database_path} <- StorageBinding.fetch(provider_module, config) do
      spawn_project_children(project_id, database_path)
    else
      false -> stop_project_children(project_id)
      {:error, _no_binding} -> stop_project_children(project_id)
    end
  end

  defp beads_provider?(ForemanServer.TaskProviders.BeadsAdapter), do: true
  defp beads_provider?(_), do: false

  # Start per-project BeadsWatcher + BeadsOrphanJanitor children. Each
  # supervisor call is gated on its own `:start_beads_*?` flag because the
  # supervisor process is absent from the supervision tree when disabled —
  # calling `start_child` against an unregistered module name would `:noproc`.
  defp spawn_project_children(project_id, database_path)
       when is_binary(project_id) and is_binary(database_path) do
    if beads_watcher_enabled?(),
      do: _ = BeadsWatcherSupervisor.start_child(project_id, database_path)

    if beads_orphan_janitor_enabled?(),
      do: _ = BeadsOrphanJanitorSupervisor.start_child(project_id, database_path)

    :ok
  end

  defp spawn_project_children(_project_id, _database_path), do: :ok

  defp stop_project_children(project_id) when is_binary(project_id) do
    if beads_watcher_enabled?(), do: _ = BeadsWatcherSupervisor.stop_child(project_id)

    if beads_orphan_janitor_enabled?(),
      do: _ = BeadsOrphanJanitorSupervisor.stop_child(project_id)

    :ok
  end

  defp beads_watcher_enabled?,
    do: Application.get_env(:foreman_server, :start_beads_watcher?, false)

  defp beads_orphan_janitor_enabled?,
    do: Application.get_env(:foreman_server, :start_beads_orphan_janitor?, false)

  # Preflight follows the provider's declared storage scheme: a `:sqlite` provider is verified
  # through its own `preflight_database/2`; a `:cli_process` provider has no database, so its
  # project must be bound to an absolute, existing directory. Neither demands the other's key.
  defp preflight_provider(provider_module, config)
       when is_atom(provider_module) and is_map(config) do
    with {:ok, scheme} <- StorageBinding.scheme(provider_module) do
      preflight_binding(provider_module, scheme, StorageBinding.fetch(provider_module, config))
    end
  end

  defp preflight_provider(_provider_module, _config), do: {:error, :preflight_failed}

  defp preflight_binding(provider_module, :sqlite, {:ok, database_path}) do
    if function_exported?(provider_module, :preflight_database, 2) do
      provider_module.preflight_database(database_path, [])
      |> normalize_preflight()
    else
      :ok
    end
  end

  defp preflight_binding(_provider_module, :sqlite, {:error, {:missing_binding_key, _key}}),
    do: {:error, :preflight_failed}

  defp preflight_binding(_provider_module, :cli_process, {:ok, cwd}) do
    cond do
      Path.type(cwd) != :absolute -> {:error, :cwd_not_absolute}
      not File.dir?(cwd) -> {:error, :cwd_not_found}
      true -> :ok
    end
  end

  defp preflight_binding(_provider_module, :cli_process, {:error, {:missing_binding_key, _key}}),
    do: {:error, :cwd_missing}

  # Total over the documented `preflight_database/2` contract
  # (`:ok | {:error, ProviderError.t()}`) and nothing else.
  #
  # This previously mapped a bare `:error` AND an `_other` catch-all to `:ok`,
  # so an out-of-contract return — including an outright failure — was reported
  # as a successful preflight and the project was registered against a database
  # that had never been verified. An unexpected shape now raises.
  defp normalize_preflight(:ok), do: :ok

  defp normalize_preflight({:error, %ProviderError{code: "DATABASE_NOT_FOUND"}}),
    do: {:error, :database_not_found}

  defp normalize_preflight({:error, %ProviderError{}}), do: {:error, :preflight_failed}

  defp normalize_preflight(other) do
    raise ArgumentError,
          "preflight_database/2 must return :ok | {:error, %ProviderError{}}; got #{inspect(other)}"
  end

  defp resolve_provider_module(provider_module) when is_atom(provider_module) do
    cond do
      function_exported?(provider_module, :capabilities, 0) ->
        {:ok, provider_module}

      true ->
        snapshot = TaskProviderRegistry.routing_snapshot()
        match = snapshot[provider_module]

        if match != nil and is_atom(match) do
          {:ok, match}
        else
          {:error, :task_provider_not_configured}
        end
    end
  end

  defp resolve_provider_module(provider_module) when is_binary(provider_module) do
    case try_full_module(provider_module) do
      {:ok, _} = ok ->
        ok

      :not_full_module ->
        # Short name like "beads" — look up the loaded module via the routing
        # snapshot. The snapshot shape is mixed: atom-keyed provider entries
        # (`%{beads => BeadsAdapter, ...}`) merged with string-keyed active
        # project entries (`%{"project-1" => BeadsAdapter, ...}`). We only
        # match against atom keys — a project ID must never be resolved as a
        # provider module. Atom.to_string/1 is only called on existing atoms,
        # so the input string is never interned.
        match =
          Enum.find_value(TaskProviderRegistry.routing_snapshot(), fn
            {id, module} when is_atom(id) ->
              if Atom.to_string(id) == provider_module, do: module

            _ ->
              nil
          end)

        if is_atom(match) and not is_nil(match) do
          {:ok, match}
        else
          {:error, :task_provider_not_configured}
        end
    end
  end

  defp resolve_provider_module(_provider_module), do: {:error, :task_provider_not_configured}

  # Validate a full module name without interning arbitrary input.
  # Module.safe_concat/1 raises ArgumentError on invalid aliases (lowercase,
  # spaces, reserved words, etc.) BEFORE creating the atom, so a malformed
  # config string can never grow the atom table.
  defp try_full_module(provider_module) when is_binary(provider_module) do
    try do
      candidate = Module.safe_concat([provider_module])

      if Code.ensure_loaded?(candidate) and function_exported?(candidate, :capabilities, 0) do
        {:ok, candidate}
      else
        :not_full_module
      end
    rescue
      ArgumentError -> :not_full_module
    end
  end
end
