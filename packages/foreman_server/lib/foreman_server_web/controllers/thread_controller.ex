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
  alias ForemanServer.Threads.Finder
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

  @doc """
  `GET /api/projects/:project_id/threads/find?q=&external_id=&branch=&pr=` -
  deterministic ranked candidates (`ForemanServer.Threads.Finder`). 400 when
  no criterion is given. Read-only: never starts a run.
  """
  def find(conn, %{"project_id" => project_id} = params) do
    opts = [
      text: params["q"],
      external_id: params["external_id"],
      branch: params["branch"],
      pr: params["pr"]
    ]

    case Finder.find(project_id, opts) do
      {:ok, candidates} ->
        conn |> put_status(:ok) |> json(%{candidates: Enum.map(candidates, &Finder.to_dto/1)})

      {:error, :no_criteria} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "invalid_params",
          detail: "one of q, external_id, branch, pr is required"
        })
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

  @doc """
  `POST /api/threads/:id/steer` with `text`, optional `message_id` and `resume`
  (boolean, workflow door). 202 `{thread_id, message_id, mode}`; 404 unknown
  thread; 409 `not_steerable` naming `status` for a terminal thread; 400 for
  blank or oversize `text` or a non-boolean `resume`; 422 when steering is
  rejected otherwise.
  """
  def steer(conn, %{"id" => id} = params) do
    with {:ok, opts} <- steer_opts(params),
         {:ok, %{message_id: message_id, mode: mode}} <-
           Actions.steer(id, Map.get(params, "text"), opts) do
      conn
      |> put_status(:accepted)
      |> json(%{thread_id: id, message_id: message_id, mode: Atom.to_string(mode)})
    else
      {:error, :thread_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "thread_not_found", thread_id: id})

      {:error, {:not_steerable, status}} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "not_steerable", thread_id: id, status: status})

      {:error, {:invalid_text, why}} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_params", detail: "text is #{why}"})

      {:error, :invalid_resume} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_params", detail: "resume must be a boolean"})

      {:error, {:steer_failed, cause}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "steer_failed", thread_id: id, detail: inspect(cause)})
    end
  end

  defp steer_opts(params) do
    message_id = blank_to_nil(Map.get(params, "message_id"))

    case Map.get(params, "resume", true) do
      resume when is_boolean(resume) ->
        {:ok, [resume: resume] |> put_present(:message_id, message_id)}

      _ ->
        {:error, :invalid_resume}
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
