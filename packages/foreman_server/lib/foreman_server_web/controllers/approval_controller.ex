defmodule ForemanServerWeb.ApprovalController do
  @moduledoc """
  Read-only list of tool-call approval requests.

    * `GET /api/projects/:id/approvals` - the project's pending requests, oldest
      first; `?status=all` also returns decided, expired and finished ones.
    * `GET /api/runs/:run_id/approvals` - one run's (or jobsite's) requests, same
      option.

  Deciding is a command (`tool.approve` / `tool.deny` on `POST /api/commands`),
  never a GET. 404 `project_not_found` / `run_not_found` for unknown ids; 400
  `invalid_params` for a bad `status`.
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.Approvals.DTO
  alias ForemanServer.{ProjectStore, ProjectionStore}

  def index_for_project(conn, %{"id" => project_id} = params) do
    with {:ok, status} <- parse_status(params),
         %{} <- ProjectStore.get(project_id) do
      render_list(conn, ProjectionStore.project_approvals(project_id, status: status))
    else
      nil -> not_found(conn, "project_not_found", project_id)
      {:error, detail} -> bad_request(conn, detail)
    end
  end

  def index_for_run(conn, %{"run_id" => run_id} = params) do
    with {:ok, status} <- parse_status(params),
         true <- run_known?(run_id) do
      render_list(conn, ProjectionStore.run_approvals(run_id, status: status))
    else
      false -> not_found(conn, "run_not_found", run_id)
      {:error, detail} -> bad_request(conn, detail)
    end
  end

  defp run_known?(run_id),
    do: ProjectionStore.run(run_id) != nil or ProjectionStore.jobsite(run_id) != nil

  defp parse_status(params) do
    case Map.get(params, "status") do
      nil -> {:ok, :pending}
      "pending" -> {:ok, :pending}
      "all" -> {:ok, :all}
      _ -> {:error, "status must be pending or all"}
    end
  end

  defp render_list(conn, calls) do
    conn |> put_status(:ok) |> json(%{"approvals" => DTO.list(calls)})
  end

  defp not_found(conn, error, id) do
    conn |> put_status(:not_found) |> json(%{error: error, id: id})
  end

  defp bad_request(conn, detail) do
    conn |> put_status(:bad_request) |> json(%{error: "invalid_params", detail: detail})
  end
end
