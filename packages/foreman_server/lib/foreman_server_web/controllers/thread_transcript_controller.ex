defmodule ForemanServerWeb.ThreadTranscriptController do
  @moduledoc """
  Structured transcript endpoints (see `ForemanServer.Threads.Transcript`).

  `GET /api/threads/:id/transcript?after=<seq>&limit=<n>` returns one page
  (`after` >= -1, default -1; `limit` 1..#{ForemanServer.Threads.Transcript.limits().max},
  default #{ForemanServer.Threads.Transcript.limits().default}); junk -> 400,
  unknown thread -> 404.

  `GET /api/threads/:id/stream?after=<seq>` is a Server-Sent Events tail. It
  first replays every turn after `after`, then emits each new turn as
  `event: turn` / `data: <turn json>`, sends a `: heartbeat` comment every
  `:thread_stream_heartbeat_ms` (default 15 000) and, once the thread is
  terminal and fully drained, sends `event: end` and closes. The projection
  subscription is held by the request process, which Cowboy ends with the
  request.
  """

  use ForemanServerWeb, :controller

  require Logger

  alias ForemanServer.ProjectionStore
  alias ForemanServer.Threads.Transcript
  alias ForemanServer.Threads.Transcript.Page
  alias ForemanServer.Threads.Turn

  @default_heartbeat_ms 15_000

  def transcript(conn, %{"id" => id} = params) do
    with {:ok, opts} <- parse_params(params),
         {:ok, %Page{} = page} <- Transcript.page(id, opts) do
      conn |> put_status(:ok) |> json(Page.to_dto(page))
    else
      {:error, {:invalid_param, detail}} -> bad_request(conn, detail)
      {:error, reason} -> page_error(conn, id, reason)
    end
  end

  def stream(conn, %{"id" => id} = params) do
    with {:ok, opts} <- parse_params(params, [:after]),
         :ok <- ProjectionStore.subscribe(replay_existing: false),
         {:ok, %Page{}} <- Transcript.page(id, Keyword.put(opts, :limit, 1)) do
      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> send_chunked(:ok)

      tail(conn, id, Keyword.fetch!(opts, :after))
    else
      {:error, {:invalid_param, detail}} -> bad_request(conn, detail)
      {:error, reason} -> page_error(conn, id, reason)
    end
  end

  # -- tail ------------------------------------------------------------------

  defp tail(conn, id, cursor) do
    case drain(conn, id, cursor) do
      {:ok, conn, _cursor, true} -> finish(conn)
      {:ok, conn, cursor, false} -> wait(conn, id, cursor, deadline())
      {:closed, conn} -> conn
    end
  end

  defp wait(conn, id, cursor, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:projection_event, event} ->
        if relevant?(event, id) do
          advance(conn, id, cursor, deadline)
        else
          wait(conn, id, cursor, deadline)
        end
    after
      remaining ->
        # A quiet period is also when the trailing agent turn becomes final
        # (gap elapsed), so re-read after the heartbeat.
        case chunk(conn, ": heartbeat\n\n") do
          {:ok, conn} -> advance(conn, id, cursor, deadline())
          {:error, _closed} -> conn
        end
    end
  end

  defp advance(conn, id, cursor, deadline) do
    case drain(conn, id, cursor) do
      {:ok, conn, _cursor, true} -> finish(conn)
      {:ok, conn, cursor, false} -> wait(conn, id, cursor, deadline)
      {:closed, conn} -> conn
    end
  end

  # Emit every turn after `cursor`; returns the new cursor and whether the
  # thread is terminal (no further turns can appear once everything is drained).
  defp drain(conn, id, cursor) do
    case Transcript.page(id, now_ms: System.system_time(:millisecond), after: cursor) do
      {:ok, %Page{turns: [], terminal: terminal}} ->
        {:ok, conn, cursor, terminal}

      {:ok, %Page{turns: turns, next_cursor: next, terminal: terminal}} ->
        case emit(conn, turns) do
          {:ok, conn} when terminal -> drain(conn, id, next)
          {:ok, conn} -> drain_more(conn, id, next)
          {:error, _closed} -> {:closed, conn}
        end

      {:error, reason} ->
        # thread vanished (projection reset) or the store failed: end the stream
        Logger.warning("thread stream #{id} ended: #{inspect(reason)}")
        {:closed, conn}
    end
  end

  defp drain_more(conn, id, cursor), do: drain(conn, id, cursor)

  defp emit(conn, turns) do
    Enum.reduce_while(turns, {:ok, conn}, fn %Turn{} = turn, {:ok, conn} ->
      case chunk(conn, "event: turn\ndata: #{Jason.encode!(Turn.to_dto(turn))}\n\n") do
        {:ok, conn} -> {:cont, {:ok, conn}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp finish(conn) do
    case chunk(conn, "event: end\ndata: {\"terminal\":true}\n\n") do
      {:ok, conn} -> conn
      {:error, _closed} -> conn
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + heartbeat_ms()

  defp heartbeat_ms,
    do: Application.get_env(:foreman_server, :thread_stream_heartbeat_ms, @default_heartbeat_ms)

  # Events that name another run/jobsite cannot change this thread. An event
  # naming nothing we can read is treated as relevant.
  defp relevant?(event, thread_id) do
    suffix = thread_id |> String.split(":", parts: 2) |> List.last()
    data = field(event, :data) || field(event, :payload) || %{}

    candidates =
      [
        field(data, :run_id),
        field(data, :jobsite_id),
        field(data, :subject_id),
        field(event, :stream_uuid),
        field(event, :stream_id)
      ]
      |> Enum.filter(&is_binary/1)

    candidates == [] or Enum.any?(candidates, &String.contains?(&1, suffix))
  end

  defp field(%{} = map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_other, _key), do: nil

  # -- params ----------------------------------------------------------------

  defp parse_params(params, keys \\ [:after, :limit]) do
    with {:ok, cursor} <- parse_after(Map.get(params, "after")),
         {:ok, limit} <- parse_limit(Map.get(params, "limit")) do
      opts = [after: cursor]
      opts = if :limit in keys and limit != nil, do: [{:limit, limit} | opts], else: opts
      {:ok, opts}
    end
  end

  defp parse_after(value) when value in [nil, ""], do: {:ok, -1}

  defp parse_after(value) when is_binary(value) do
    case Integer.parse(value) do
      {cursor, ""} when cursor >= -1 -> {:ok, cursor}
      _ -> {:error, {:invalid_param, "after must be an integer >= -1"}}
    end
  end

  defp parse_after(_), do: {:error, {:invalid_param, "after must be an integer >= -1"}}

  defp parse_limit(value) when value in [nil, ""], do: {:ok, nil}

  defp parse_limit(value) when is_binary(value) do
    max = Transcript.limits().max

    case Integer.parse(value) do
      {limit, ""} when limit >= 1 and limit <= max -> {:ok, limit}
      _ -> {:error, {:invalid_param, "limit must be an integer between 1 and #{max}"}}
    end
  end

  defp parse_limit(_), do: {:error, {:invalid_param, "limit must be an integer"}}

  defp bad_request(conn, detail) do
    conn |> put_status(:bad_request) |> json(%{error: "invalid_params", detail: detail})
  end

  defp page_error(conn, id, :thread_not_found) do
    conn |> put_status(:not_found) |> json(%{error: "thread_not_found", thread_id: id})
  end

  defp page_error(conn, id, reason) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{error: "transcript_unavailable", thread_id: id, detail: inspect(reason)})
  end
end
