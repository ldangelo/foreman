defmodule ForemanServerWeb.RecommendationsController do
  @moduledoc """
  `GET /api/projects/:id/recommendations` - setup recommendations
  (`ForemanServer.Projects.Recommendations`). Read-only: collecting facts runs
  bounded probes but never changes state. 404 for an unknown project, 504 when
  the whole collection exceeds its budget.

  `config :foreman_server, :recommendations, probe:, probe_timeout_ms:,
  total_timeout_ms:` overrides the probe and budgets (test seam); see
  `Recommendations.recommend_bounded/1`, which the MCP tool, `foreman doctor`
  and the coordinator share with this action.
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.Projects.Recommendations
  alias ForemanServer.Projects.Recommendations.View

  def show(conn, %{"id" => project_id}) do
    case Recommendations.recommend_bounded(project_id) do
      {:ok, recommendations} ->
        conn |> put_status(:ok) |> json(View.serialise(project_id, recommendations))

      {:error, :project_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "project_not_found"})

      {:error, :timeout} ->
        conn |> put_status(:gateway_timeout) |> json(%{error: "recommendations_timeout"})
    end
  end
end
