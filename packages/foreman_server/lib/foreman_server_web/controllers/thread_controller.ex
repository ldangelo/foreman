defmodule ForemanServerWeb.ThreadController do
  @moduledoc """
  Thread read-model endpoints.

  `GET /api/projects/:project_id/threads` lists threads (`status`, `door`,
  `limit` filters); `GET /api/threads/:id` returns one. Bodies use the
  whitelisted string-keyed DTO from `ForemanServer.Threads.Thread.to_dto/1`.
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.Threads
  alias ForemanServer.Threads.Actions
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

  @doc """
  `POST /api/threads/:id/stop` with optional `reason` and `idempotency_key`.
  200 `{thread_id, requested: "stopping"}`; 404 unknown thread; 409 when the
  thread is terminal (`not_stoppable`) or its jobsite has no executor
  (`no_executor`), both naming `status`; 422 when the cancel is rejected.
  """
  def stop(conn, %{"id" => id} = params) do
    opts =
      case Map.get(params, "idempotency_key") do
        key when is_binary(key) and key != "" -> [idempotency_key: key]
        _ -> []
      end

    case Actions.stop(id, Map.get(params, "reason"), opts) do
      {:ok, :stopping} ->
        conn |> put_status(:ok) |> json(%{thread_id: id, requested: "stopping"})

      {:error, :thread_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "thread_not_found", thread_id: id})

      {:error, {code, status}} when code in [:not_stoppable, :no_executor] ->
        conn
        |> put_status(:conflict)
        |> json(%{error: Atom.to_string(code), thread_id: id, status: status})

      {:error, {:cancel_failed, cause}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "cancel_failed", thread_id: id, detail: inspect(cause)})
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
