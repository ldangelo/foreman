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
      config: %{},
      health: %{ok: true}
    }

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "ProjectRegistered" ->
        %State{
          state
          | exists?: true,
            project_id: Aggregate.get(payload, :project_id),
            path: Aggregate.get(payload, :path),
            status: Aggregate.get(payload, :status, "active"),
            default_branch: Aggregate.get(payload, :default_branch, "main"),
            config: Aggregate.get(payload, :config, %{}),
            health: Aggregate.get(payload, :health, %{ok: true}),
            archived?: false
        }

      "ProjectUpdated" ->
        new_config = Map.merge(state.config, Aggregate.get(payload, :config, %{}))

        config =
          if name = Aggregate.get(payload, :name),
            do: Map.put(new_config, :name, name),
            else: new_config

        state
        |> update_status(payload)
        |> update_default_branch(payload)
        |> update_health(payload)
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
         :ok <- validate_status(Aggregate.get(payload, :status, "active")) do
      {:ok,
       %ForemanServer.Events.ProjectRegistered{
         project_id: project_id,
         path: path,
         status: Aggregate.get(payload, :status, "active"),
         default_branch: Aggregate.get(payload, :default_branch, "main"),
         config: Aggregate.get(payload, :config),
         health: Aggregate.get(payload, :health)
       }}
    end
  end

  def handle_command(state, %{type: "project.update", payload: payload}) do
    with {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         :ok <- require_exists(state, project_id) do
      {:ok,
       %ForemanServer.Events.ProjectUpdated{
         project_id: project_id,
         name: Aggregate.get(payload, :name),
         status: Aggregate.get(payload, :status),
         default_branch: Aggregate.get(payload, :default_branch),
         config: Aggregate.get(payload, :config),
         health: Aggregate.get(payload, :health)
       }}
    end
  end

  def handle_command(state, %{type: "project.archive", payload: payload}) do
    with {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         :ok <- require_exists(state, project_id),
         :ok <- validate_archive(state) do
      {:ok, %ForemanServer.Events.ProjectArchived{project_id: project_id}}
    end
  end

  def handle_command(state, %{type: "project.reactivate", payload: payload}) do
    with {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         :ok <- require_exists(state, project_id),
         :ok <- validate_reactivate(state) do
      {:ok, %ForemanServer.Events.ProjectReactivated{project_id: project_id}}
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

  defp put_config(state, config), do: %State{state | config: config}
end
