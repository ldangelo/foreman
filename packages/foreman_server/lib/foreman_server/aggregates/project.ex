defmodule ForemanServer.Aggregates.Project do
  @moduledoc "Project aggregate: validates registration/config/archive commands."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  @valid_statuses MapSet.new(["active", "paused", "archived"])

  @impl true
  def initial_state, do: %{exists?: false, status: nil, config: %{}}

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "ProjectRegistered" ->
        state
        |> Map.merge(%{
          exists?: true,
          project_id: Aggregate.get(payload, :project_id),
          path: Aggregate.get(payload, :path),
          status: Aggregate.get(payload, :status, "active"),
          default_branch: Aggregate.get(payload, :default_branch, "main"),
          config: Aggregate.get(payload, :config, %{}),
          health: Aggregate.get(payload, :health, %{ok: true}),
          archived?: false
        })

      "ProjectUpdated" ->
        config = Map.merge(Map.get(state, :config, %{}), Aggregate.get(payload, :config, %{}))

        config =
          if name = Aggregate.get(payload, :name), do: Map.put(config, :name, name), else: config

        state
        |> Aggregate.put_if(:status, Aggregate.get(payload, :status))
        |> Aggregate.put_if(:default_branch, Aggregate.get(payload, :default_branch))
        |> Aggregate.put_if(:health, Aggregate.get(payload, :health))
        |> Map.put(:config, config)

      "ProjectArchived" ->
        state |> Map.put(:status, "archived") |> Map.put(:archived?, true)

      "ProjectReactivated" ->
        state |> Map.put(:status, "active") |> Map.put(:archived?, false)

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

  defp require_absent(%{exists?: true}, project_id),
    do: {:error, {:already_exists, :project, project_id}}

  defp require_absent(_state, _project_id), do: :ok

  defp require_exists(%{exists?: true}, _project_id), do: :ok
  defp require_exists(_state, project_id), do: {:error, {:not_found, :project, project_id}}

  defp validate_status(nil), do: :ok

  defp validate_status(status) when is_binary(status) do
    if MapSet.member?(@valid_statuses, status),
      do: :ok,
      else: {:error, {:invalid_project_status, status}}
  end

  defp validate_status(status), do: {:error, {:invalid_project_status, status}}
end
