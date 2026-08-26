defmodule ForemanServerWeb.RunController do
  @moduledoc """
  Run read-model endpoint.

  `GET /api/runs` returns projected runs with optional filters.
  `GET /api/runs/:id` returns the projected state for a single run.
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.ProjectionStore

  def index(conn, params) do
    opts =
      []
      |> maybe_put_opt(:status, Map.get(params, "status"))
      |> maybe_put_opt(:project_id, Map.get(params, "project_id"))
      |> maybe_put_limit(Map.get(params, "limit"))

    conn
    |> put_status(:ok)
    |> json(%{runs: ProjectionStore.list_runs(opts) |> stringify_keys()})
  end

  def show(conn, %{"id" => run_id}) do
    case ProjectionStore.run(run_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "run_not_found", run_id: run_id})

      projection when is_map(projection) ->
        conn
        |> put_status(:ok)
        |> json(%{run: stringify_keys(projection)})
    end
  end

  defp maybe_put_opt(opts, _key, value) when value in [nil, ""], do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_limit(opts, nil), do: opts
  defp maybe_put_limit(opts, ""), do: opts

  defp maybe_put_limit(opts, value) do
    case Integer.parse(value) do
      {limit, ""} when limit > 0 -> Keyword.put(opts, :limit, limit)
      _ -> opts
    end
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
