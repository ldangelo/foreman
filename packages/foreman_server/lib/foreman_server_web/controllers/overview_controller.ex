defmodule ForemanServerWeb.OverviewController do
  @moduledoc """
  `GET /api/projects/:project_id/overview` - the project Overview.

  Query: `include_resolved` (`true|false`, default false) and `resolved_limit`
  (integer 0..200, default 20). 404 `project_not_found` for an unknown project;
  400 `invalid_params` for a bad query value. Read-only: it exposes no merge or
  approve action (see `ForemanServer.Overview`).
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.{Overview, ProjectStore}

  @max_resolved_limit 200

  def show(conn, %{"project_id" => project_id} = params) do
    with {:ok, opts} <- parse_opts(params),
         %{} <- ProjectStore.get(project_id) do
      {:ok, overview} = Overview.build(project_id, opts)
      conn |> put_status(:ok) |> json(Overview.to_dto(overview))
    else
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "project_not_found", project_id: project_id})

      {:error, detail} ->
        conn |> put_status(:bad_request) |> json(%{error: "invalid_params", detail: detail})
    end
  end

  defp parse_opts(params) do
    with {:ok, include_resolved} <- parse_bool(params, "include_resolved", false),
         {:ok, limit} <- parse_limit(params) do
      {:ok, [include_resolved: include_resolved, resolved_limit: limit]}
    end
  end

  defp parse_bool(params, key, default) do
    case Map.get(params, key) do
      nil -> {:ok, default}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:error, "#{key} must be true or false"}
    end
  end

  defp parse_limit(params) do
    case Map.get(params, "resolved_limit") do
      nil ->
        {:ok, Overview.default_resolved_limit()}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, ""} when n >= 0 and n <= @max_resolved_limit -> {:ok, n}
          _ -> {:error, "resolved_limit must be an integer 0..#{@max_resolved_limit}"}
        end

      _ ->
        {:error, "resolved_limit must be an integer 0..#{@max_resolved_limit}"}
    end
  end
end
