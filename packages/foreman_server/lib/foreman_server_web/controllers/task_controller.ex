defmodule ForemanServerWeb.TaskController do
  @moduledoc """
  Task read-model endpoint.

  `GET /api/tasks/:id` returns the projected state for a single task.
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.ProjectionStore

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
