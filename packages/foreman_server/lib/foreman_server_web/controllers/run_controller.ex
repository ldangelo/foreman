defmodule ForemanServerWeb.RunController do
  @moduledoc """
  Run read-model endpoint.

  `GET /api/runs/:id` returns the projected state for a single run.
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.ProjectionStore

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

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
