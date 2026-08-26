defmodule ForemanServerWeb.QueueController do
  @moduledoc """
  Queue read-model endpoint.

  `GET /api/queue` returns the current global run-slot queue status.
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.ProjectionStore

  def index(conn, _params) do
    conn
    |> put_status(:ok)
    |> json(stringify_keys(ProjectionStore.queue_status()))
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
