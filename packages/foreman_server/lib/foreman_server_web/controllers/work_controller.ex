defmodule ForemanServerWeb.WorkController do
  use ForemanServerWeb, :controller

  alias ForemanServer.ProjectionStore

  def show(conn, %{"id" => work_id}) do
    case ProjectionStore.work_projection(work_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "work_not_found"})

      work ->
        json(conn, work)
    end
  end
end
