defmodule ForemanServerWeb.DoctorController do
  @moduledoc """
  `GET /api/doctor[?project=<id>]` - the checks `foreman doctor` can honestly
  perform, composed from existing seams:

    * `server` - the request itself reached the server;
    * `event_store` - the read model answers (`ProjectionStore.queue_status/0`);
    * `provider.<name>` - one row per jido_harness provider
      (`MCP.Tools.Doctor.rows/0`, the same data as the `foreman_doctor` MCP tool);
    * `workflows` - the workflow catalog has manifests installed;
    * `project.recommendations` - with `?project=`, counts of setup
      recommendations by severity (`Projects.Recommendations`).

  Each check is `%{id, status: ok|warn|fail, title, detail}`. Pi SDK, DB
  integrity, zombie-run, stale-worktree and auto-fix checks do NOT exist.
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.ProjectionStore
  alias ForemanServer.Workflow.Catalog
  alias ForemanServerWeb.MCP.Tools.Doctor
  alias ForemanServerWeb.RecommendationsController

  def show(conn, params) do
    project_check =
      case params["project"] do
        id when is_binary(id) and id != "" -> [project_check(id)]
        _ -> []
      end

    checks =
      [check("server", :ok, "Server reachable", "The server answered this request.")] ++
        [event_store_check()] ++ provider_checks() ++ [workflows_check()] ++ project_check

    case Enum.find(project_check, &(&1["status"] == "not_found")) do
      nil -> conn |> put_status(:ok) |> json(%{checks: checks})
      _ -> conn |> put_status(:not_found) |> json(%{error: "project_not_found"})
    end
  end

  defp event_store_check do
    ProjectionStore.queue_status()
    check("event_store", :ok, "Read model reachable", "The projection store answered.")
  catch
    :exit, reason ->
      check("event_store", :fail, "Read model unreachable", inspect(reason))
  end

  defp provider_checks do
    case safely(&Doctor.rows/0) do
      {:ok, rows} ->
        for {:provider, name, status, hint} <- rows do
          case status do
            :installed ->
              check("provider.#{name}", :ok, "#{name} installed", "#{name} is available.")

            :not_installed ->
              check("provider.#{name}", :warn, "#{name} not installed", to_string(hint))
          end
        end

      :error ->
        [check("providers", :warn, "Provider readiness unknown", "The readiness probe failed.")]
    end
  end

  defp workflows_check do
    case safely(&Catalog.installed?/0) do
      {:ok, true} ->
        check("workflows", :ok, "Workflows installed", "The workflow catalog has manifests.")

      {:ok, false} ->
        check("workflows", :warn, "No workflows installed", "Run `foreman workflow install`.")

      :error ->
        check("workflows", :warn, "Workflow catalog unknown", "The catalog did not answer.")
    end
  end

  defp project_check(id) do
    case RecommendationsController.recommend(id) do
      {:ok, recs} ->
        counts = Enum.frequencies_by(recs, & &1.severity)
        actions = Map.get(counts, :action, 0)
        warns = Map.get(counts, :warn, 0)
        infos = Map.get(counts, :info, 0)

        status = if actions + warns > 0, do: :warn, else: :ok

        check(
          "project.recommendations",
          status,
          "Project #{id} setup",
          "#{actions} action, #{warns} warn, #{infos} info recommendations. " <>
            "Run `foreman project recommend #{id}`."
        )

      {:error, :project_not_found} ->
        %{"id" => "project.recommendations", "status" => "not_found"}

      {:error, :timeout} ->
        check("project.recommendations", :warn, "Project setup unknown", "The check timed out.")
    end
  end

  defp safely(fun) do
    {:ok, fun.()}
  catch
    _kind, _reason -> :error
  end

  defp check(id, status, title, detail),
    do: %{"id" => id, "status" => Atom.to_string(status), "title" => title, "detail" => detail}
end
