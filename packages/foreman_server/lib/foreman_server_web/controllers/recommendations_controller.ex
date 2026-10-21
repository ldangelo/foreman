defmodule ForemanServerWeb.RecommendationsController do
  @moduledoc """
  `GET /api/projects/:id/recommendations` - setup recommendations
  (`ForemanServer.Projects.Recommendations`). Read-only: collecting facts runs
  bounded probes but never changes state. 404 for an unknown project, 504 when
  the whole collection exceeds its budget.

  `config :foreman_server, :recommendations, probe:, probe_timeout_ms:,
  total_timeout_ms:` overrides the probe and budgets (test seam).
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.Projects.Recommendations
  alias ForemanServer.Projects.Recommendations.{Facts, View}

  def show(conn, %{"id" => project_id}) do
    case recommend(project_id) do
      {:ok, recommendations} ->
        conn |> put_status(:ok) |> json(View.serialise(project_id, recommendations))

      {:error, :project_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "project_not_found"})

      {:error, :timeout} ->
        conn |> put_status(:gateway_timeout) |> json(%{error: "recommendations_timeout"})
    end
  end

  @doc "Shared by the MCP tool so HTTP and MCP cannot drift."
  @spec recommend(String.t()) ::
          {:ok, [Recommendations.Recommendation.t()]} | {:error, :project_not_found | :timeout}
  def recommend(project_id) do
    config = Application.get_env(:foreman_server, :recommendations, [])
    total = Keyword.get(config, :total_timeout_ms, Facts.total_timeout_ms())

    opts =
      config
      |> Keyword.take([:probe, :probe_timeout_ms])
      |> Keyword.put(:deadline_ms, System.monotonic_time(:millisecond) + total)

    # Per-probe bounds hold the collection to ~`total`; this outer bound is the
    # guarantee, with one probe's worth of slack so a late last probe still counts.
    outer = total + Keyword.get(opts, :probe_timeout_ms, Facts.probe_timeout_ms())

    case Facts.Probe.System.call(fn -> Recommendations.recommend(project_id, opts) end, outer) do
      {:ok, result} -> result
      {:error, :timeout} -> {:error, :timeout}
      {:error, :failed} -> raise "project recommendations failed for #{project_id}"
    end
  end
end
