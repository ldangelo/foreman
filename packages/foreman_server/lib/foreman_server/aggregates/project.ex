defmodule ForemanServer.Aggregates.Project do
  @moduledoc "Project aggregate: validates registration/config/archive commands."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  defmodule State do
    @enforce_keys []
    defstruct [
      :exists?,
      :project_id,
      :path,
      :status,
      :default_branch,
      :config,
      :health,
      :archived?
    ]

    @type t :: %__MODULE__{
            exists?: boolean,
            project_id: String.t() | nil,
            path: String.t() | nil,
            status: String.t() | nil,
            default_branch: String.t() | nil,
            config: map(),
            health: map(),
            archived?: boolean
          }
  end

  @valid_statuses MapSet.new(["active", "paused", "archived"])

  @impl true
  def initial_state,
    do: %State{
      exists?: false,
      project_id: nil,
      path: nil,
      status: nil,
      default_branch: nil,
      config: %{},
      health: %{},
      archived?: false
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
        config = Map.merge(state.config, Aggregate.get(payload, :config, %{}))

        config =
          if name = Aggregate.get(payload, :name), do: Map.put(config, :name, name), else: config

        s1 =
          if(status = Aggregate.get(payload, :status),
            do: %State{state | status: status},
            else: state
          )

        s2 =
          if(db = Aggregate.get(payload, :default_branch),
            do: %State{s1 | default_branch: db},
            else: s1
          )

        s3 =
          if(health = Aggregate.get(payload, :health), do: %State{s2 | health: health}, else: s2)

        %State{s3 | config: config}

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
       %{
         stream_id: "project:#{project_id}",
         event_type: "ProjectRegistered",
         payload: %{
           project_id: project_id,
           path: path,
           status: Aggregate.get(payload, :status, "active"),
           default_branch: Aggregate.get(payload, :default_branch, "main"),
           config: Aggregate.get(payload, :config, %{}),
           health: Aggregate.get(payload, :health, %{ok: true})
         }
       }}
    end
  end

  def handle_command(state, %{type: "project.update", payload: payload}) do
    project_id = Aggregate.get(payload, :project_id) || Aggregate.get(payload, :id)

    with {:ok, project_id} <- Aggregate.required_binary(project_id, :project_id),
         :ok <- require_exists(state, project_id),
         :ok <- validate_status(Aggregate.get(payload, :status)) do
      {:ok,
       %{
         stream_id: "project:#{project_id}",
         event_type: "ProjectUpdated",
         payload: Map.put(payload, :project_id, project_id)
       }}
    end
  end

  def handle_command(state, %{type: "project.archive", payload: payload}) do
    project_id = Aggregate.get(payload, :project_id) || Aggregate.get(payload, :id)

    with {:ok, project_id} <- Aggregate.required_binary(project_id, :project_id),
         :ok <- require_exists(state, project_id) do
      {:ok,
       %{
         stream_id: "project:#{project_id}",
         event_type: "ProjectArchived",
         payload: %{
           project_id: project_id,
           status: "archived",
           force: Aggregate.get(payload, :force, false),
           reason: Aggregate.get(payload, :reason)
         }
       }}
    end
  end

  def handle_command(state, %{type: "project.reactivate", payload: payload}) do
    project_id = Aggregate.get(payload, :project_id) || Aggregate.get(payload, :id)

    with {:ok, project_id} <- Aggregate.required_binary(project_id, :project_id),
         :ok <- require_exists(state, project_id) do
      {:ok,
       %{
         stream_id: "project:#{project_id}",
         event_type: "ProjectReactivated",
         payload: %{project_id: project_id, status: "active"}
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp require_absent(%State{exists?: true}, project_id),
    do: {:error, {:already_exists, :project, project_id}}

  defp require_absent(%State{}, _project_id), do: :ok

  defp require_exists(%State{exists?: true}, _project_id), do: :ok
  defp require_exists(%State{}, project_id), do: {:error, {:not_found, :project, project_id}}

  defp validate_status(nil), do: :ok

  defp validate_status(status) when is_binary(status) do
    if MapSet.member?(@valid_statuses, status),
      do: :ok,
      else: {:error, {:invalid_project_status, status}}
  end

  defp validate_status(status), do: {:error, {:invalid_project_status, status}}
end
