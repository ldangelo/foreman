defmodule ForemanServerWeb.QuestionController do
  @moduledoc """
  Read-only list of operator questions: `GET /api/projects/:id/questions`
  (open ones, oldest first; `?status=all` adds answered and expired). The body is a
  `ForemanServer.Questions.Listing`, the payload the `foreman_questions_list` MCP tool
  returns too.

  Answering is a command (`question.answer` on `POST /api/commands`). 404
  `project_not_found` for an unknown project; 400 `invalid_params` for a bad
  `status`.
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.Questions.Listing
  alias ForemanServer.{ProjectStore, ProjectionStore}

  def index(conn, %{"id" => project_id} = params) do
    with {:ok, status} <- parse_status(params),
         %{} <- ProjectStore.get(project_id) do
      questions = ProjectionStore.project_questions(project_id, status: status)
      conn |> put_status(:ok) |> json(Listing.build(questions))
    else
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "project_not_found", id: project_id})

      {:error, detail} ->
        conn |> put_status(:bad_request) |> json(%{error: "invalid_params", detail: detail})
    end
  end

  defp parse_status(params) do
    case Map.get(params, "status") do
      nil -> {:ok, :pending}
      "pending" -> {:ok, :pending}
      "all" -> {:ok, :all}
      _ -> {:error, "status must be pending or all"}
    end
  end
end
