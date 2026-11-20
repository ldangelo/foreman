defmodule ForemanServerWeb.QueueController do
  @moduledoc """
  Queue read-model endpoint.

  `GET /api/queue?project_id=<id>` returns ONE project's run-slot queue: limit,
  running and waiting counts, the running run ids and the waiting runs in order.
  There is no combined view: a request that names no project is refused with 422
  `project_required`, and an unknown project is 404 `project_not_found`.
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.{ProjectionStore, ProjectStore}

  @project_required_message "name a project: GET /api/queue?project_id=<id>"

  def index(conn, params) do
    case project_id(params) do
      nil ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "project_required", message: @project_required_message})

      project_id ->
        case ProjectStore.get(project_id) do
          nil ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "project_not_found", project_id: project_id})

          _project ->
            conn
            |> put_status(:ok)
            |> json(stringify_keys(ProjectionStore.queue_status(project_id)))
        end
    end
  end

  defp project_id(%{"project_id" => id}) when is_binary(id) do
    case String.trim(id) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp project_id(_params), do: nil

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
