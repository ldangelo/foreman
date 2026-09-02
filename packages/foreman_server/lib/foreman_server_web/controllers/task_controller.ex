defmodule ForemanServerWeb.TaskController do
  @moduledoc """
  Task read-model endpoint.

  `GET /api/tasks/:id` returns the projected state for a single task.
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.ProjectionStore

  def index(conn, params) do
    all_tasks = ProjectionStore.list_tasks()

    filtered =
      Enum.filter(all_tasks, fn task ->
        project_match = params["project_id"] == nil ||
                         Map.get(task, :project_id) == params["project_id"]
        status_match = params["status"] == nil ||
                         Map.get(task, :status) == params["status"]
        project_match && status_match
      end)

    conn
    |> put_status(:ok)
    |> json(%{tasks: stringify_keys(filtered), total: length(filtered)})
  end

  def show(conn, %{"id" => task_id}) do
    case ProjectionStore.task_projection(task_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "task_not_found", task_id: task_id})

      projection when is_map(projection) ->
        conn
        |> put_status(:ok)
        |> json(%{task: stringify_keys(projection)})
    end
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
