defmodule ForemanServerWeb.ThreadController do
  @moduledoc """
  Thread read-model endpoints.

  `GET /api/projects/:project_id/threads` lists threads (`status`, `door`,
  `limit` filters); `GET /api/threads/:id` returns one. Bodies use the
  whitelisted string-keyed DTO from `ForemanServer.Threads.Thread.to_dto/1`.
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.Threads
  alias ForemanServer.Threads.Thread

  def index(conn, %{"project_id" => project_id} = params) do
    with {:ok, opts} <- parse_opts(params) do
      threads = project_id |> Threads.list(opts) |> Enum.map(&Thread.to_dto/1)

      conn
      |> put_status(:ok)
      |> json(%{threads: threads})
    else
      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_params", detail: reason})
    end
  end

  def show(conn, %{"id" => id}) do
    case Threads.get(id) do
      {:ok, thread} ->
        conn |> put_status(:ok) |> json(%{thread: Thread.to_dto(thread)})

      {:error, :thread_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "thread_not_found", thread_id: id})
    end
  end

  defp parse_opts(params) do
    with {:ok, limit} <- parse_limit(Map.get(params, "limit")),
         {:ok, door} <- parse_door(Map.get(params, "door")) do
      opts =
        []
        |> put_present(:limit, limit)
        |> put_present(:door, door)
        |> put_present(:status, blank_to_nil(Map.get(params, "status")))

      {:ok, opts}
    end
  end

  defp parse_limit(nil), do: {:ok, nil}

  defp parse_limit(value) when is_binary(value) do
    max = Threads.max_limit()

    case Integer.parse(value) do
      {limit, ""} when limit >= 1 and limit <= max -> {:ok, limit}
      _ -> {:error, "limit must be an integer between 1 and #{max}"}
    end
  end

  defp parse_limit(_), do: {:error, "limit must be an integer"}

  defp parse_door(value) when value in [nil, ""], do: {:ok, nil}
  defp parse_door("workflow"), do: {:ok, :workflow}
  defp parse_door("jobsite"), do: {:ok, :jobsite}
  defp parse_door(_), do: {:error, "door must be workflow or jobsite"}

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_), do: nil

  defp put_present(opts, _key, nil), do: opts
  defp put_present(opts, key, value), do: Keyword.put(opts, key, value)
end
