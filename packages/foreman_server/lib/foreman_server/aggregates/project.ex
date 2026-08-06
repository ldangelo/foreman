defmodule ForemanServer.Aggregates.Project do
  @moduledoc "Project aggregate: validates registration/config/archive commands."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  defmodule State do
    @enforce_keys [:exists?, :project_id, :path, :status, :default_branch, :archived?]
    defstruct [
      :exists?,
      :project_id,
      :path,
      :status,
      :default_branch,
      :archived?,
      :task_provider,
      config: %{},
      health: %{ok: true}
    ]
  end

  @valid_statuses MapSet.new(["active", "paused", "archived"])

  @impl true
  def initial_state,
    do: %State{
      exists?: false,
      project_id: nil,
      path: nil,
      status: nil,
      default_branch: "main",
      archived?: false,
      task_provider: nil,
      config: %{},
      health: %{ok: true}
    }

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "ProjectRegistered" ->
        task_provider = task_provider_from(payload)

        %State{
          state
          | exists?: true,
            project_id: Aggregate.get(payload, :project_id),
            path: Aggregate.get(payload, :path),
            status: Aggregate.get(payload, :status, "active"),
            default_branch: Aggregate.get(payload, :default_branch, "main"),
            task_provider: task_provider,
            config: project_config(payload, task_provider),
            health: Aggregate.get(payload, :health, %{ok: true}),
            archived?: false
        }

      "ProjectUpdated" ->
        task_provider = task_provider_from(payload)

        config =
          state.config
          |> merge_config(Aggregate.get(payload, :config, %{}))
          |> maybe_put_name(Aggregate.get(payload, :name))
          |> maybe_put_task_provider(task_provider)

        state
        |> update_status(payload)
        |> update_default_branch(payload)
        |> update_health(payload)
        |> put_task_provider(task_provider)
        |> put_config(config)

      "ProjectArchived" ->
        %State{state | status: "archived", archived?: true}

      "ProjectReactivated" ->
        %State{state | status: "active", archived?: false}

      _ ->
        state
    end
  end

  @impl true
  def handle_command(state, %{type: "project.register", payload: payload}) do
    project_id = Aggregate.get(payload, :project_id) || Aggregate.get(payload, :id)

    with {:ok, project_id} <- Aggregate.required_binary(project_id, :project_id),
         {:ok, path} <- Aggregate.required_binary(Aggregate.get(payload, :path), :path),
         :ok <- require_absent(state, project_id),
         :ok <- validate_status(Aggregate.get(payload, :status, "active")),
         {:ok, payload} <-
           payload
           |> Map.put(:project_id, project_id)
           |> Map.put(:path, path)
           |> normalize_task_provider_payload() do
      {:ok,
       %{
         stream_id: "project:#{project_id}",
         event_type: "ProjectRegistered",
         payload: payload
       }}
    end
  end

  def handle_command(state, %{type: "project.update", payload: payload}) do
    with {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         :ok <- require_exists(state, project_id),
         {:ok, payload} <-
           payload
           |> Map.put(:project_id, project_id)
           |> normalize_task_provider_payload() do
      {:ok,
       %{
         stream_id: "project:#{project_id}",
         event_type: "ProjectUpdated",
         payload: payload
       }}
    end
  end

  def handle_command(state, %{type: "project.archive", payload: payload}) do
    with {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         :ok <- require_exists(state, project_id),
         :ok <- validate_archive(state) do
      {:ok,
       %{
         stream_id: "project:#{project_id}",
         event_type: "ProjectArchived",
         payload: Map.merge(payload, %{project_id: project_id})
       }}
    end
  end

  def handle_command(state, %{type: "project.reactivate", payload: payload}) do
    with {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         :ok <- require_exists(state, project_id),
         :ok <- validate_reactivate(state) do
      {:ok,
       %{
         stream_id: "project:#{project_id}",
         event_type: "ProjectReactivated",
         payload: Map.merge(payload, %{project_id: project_id})
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp require_absent(%State{exists?: true}, project_id),
    do: {:error, {:already_exists, :project, project_id}}

  defp require_absent(_state, _project_id), do: :ok

  defp require_exists(%State{exists?: true}, _project_id), do: :ok
  defp require_exists(_state, project_id), do: {:error, {:not_found, :project, project_id}}

  defp validate_status(nil), do: :ok

  defp validate_status(status) when is_binary(status) do
    if MapSet.member?(@valid_statuses, status),
      do: :ok,
      else: {:error, {:invalid_project_status, status}}
  end

  defp validate_status(status), do: {:error, {:invalid_project_status, status}}

  defp validate_archive(%State{archived?: true}), do: {:error, {:already_archived, :project}}
  defp validate_archive(_state), do: :ok

  defp validate_reactivate(%State{archived?: false}), do: {:error, {:not_archived, :project}}
  defp validate_reactivate(_state), do: :ok

  defp update_status(state, payload) do
    if status = Aggregate.get(payload, :status),
      do: %State{state | status: status},
      else: state
  end

  defp update_default_branch(state, payload) do
    if db = Aggregate.get(payload, :default_branch),
      do: %State{state | default_branch: db},
      else: state
  end

  defp update_health(state, payload) do
    if health = Aggregate.get(payload, :health),
      do: %State{state | health: health},
      else: state
  end

  defp put_task_provider(state, nil), do: state
  defp put_task_provider(state, task_provider), do: %State{state | task_provider: task_provider}

  defp put_config(state, config), do: %State{state | config: config}

  defp normalize_task_provider_payload(payload) do
    case payload |> task_provider_from() |> normalize_task_provider() do
      {:ok, nil} ->
        {:ok, payload}

      {:ok, task_provider} ->
        config =
          payload
          |> Aggregate.get(:config, %{})
          |> maybe_put_task_provider(task_provider)

        {:ok,
         payload
         |> Map.put(:task_provider, task_provider)
         |> Map.put(:config, config)}

      {:error, :database_path_must_be_absolute} = error ->
        error
    end
  end

  defp normalize_task_provider(nil), do: {:ok, nil}

  defp normalize_task_provider(task_provider) do
    case task_provider_database_path(task_provider) do
      nil ->
        {:ok, task_provider}

      database_path when is_binary(database_path) ->
        with :ok <- validate_database_path(database_path) do
          {:ok, put_task_provider_database_path(task_provider, Path.expand(database_path))}
        end
    end
  end

  defp task_provider_database_path(task_provider) do
    task_provider
    |> Aggregate.get(:config, %{})
    |> Aggregate.get(:database_path)
  end

  defp put_task_provider_database_path(task_provider, database_path) do
    config =
      task_provider
      |> Aggregate.get(:config, %{})
      |> put_map_value(:database_path, database_path)

    put_map_value(task_provider, :config, config)
  end

  defp validate_database_path(database_path) when is_binary(database_path) do
    if Path.type(database_path) == :absolute,
      do: :ok,
      else: {:error, :database_path_must_be_absolute}
  end

  defp project_config(payload, task_provider) do
    payload
    |> Aggregate.get(:config, %{})
    |> maybe_put_task_provider(task_provider)
  end

  defp task_provider_from(payload) do
    case Aggregate.get(payload, :task_provider) do
      nil -> payload |> Aggregate.get(:config, %{}) |> Aggregate.get(:task_provider)
      task_provider -> task_provider
    end
  end

  defp maybe_put_name(config, nil), do: config
  defp maybe_put_name(config, name), do: Map.put(config, :name, name)

  defp maybe_put_task_provider(config, nil), do: config

  defp maybe_put_task_provider(config, task_provider),
    do: put_map_value(config, :task_provider, task_provider)

  defp merge_config(left, right) when is_map(left) and is_map(right) do
    Enum.reduce(right, left, fn {key, value}, acc -> Map.put(acc, key, value) end)
  end

  defp put_map_value(map, key, value) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, string_key) -> Map.put(map, string_key, value)
      true -> Map.put(map, key, value)
    end
  end
end
