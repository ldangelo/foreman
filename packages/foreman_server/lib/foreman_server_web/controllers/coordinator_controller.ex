defmodule ForemanServerWeb.CoordinatorController do
  @moduledoc """
  HTTP surface of a project's coordinator conversation.

    * `POST /api/projects/:id/coordinator/messages` body `{text, message_id?, source?}`
      -> 202 `{message_id, seq}`; a repeated `message_id` returns the original
      `seq` and appends nothing. `source` defaults to `"http"` and may only be
      `cli|http|dashboard` (`mcp` is reserved for the MCP tool).
    * `GET /api/projects/:id/coordinator/messages?after=&limit=&wait_ms=`
      -> 200 whitelisted page + `status`, long-polling up to `wait_ms` (0..25000).
      Never mutates.
    * `GET /api/projects/:id/coordinator` -> 200 status.
    * `POST /api/projects/:id/coordinator/restart` -> 200 status after
      dispatching `coordinator.restart`.

  Errors: `{"error": "<code>", "message": "..."}` with 404 `project_not_found`,
  409 `project_archived`, 413 `message_too_large`, 422 `invalid_*`.
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.CoordinatorAPI

  @http_sources ~w(cli http dashboard)

  def post_message(conn, %{"id" => project_id} = params) do
    with {:ok, text} <- text_param(params),
         {:ok, source} <- source_param(params),
         {:ok, message_id} <- message_id_param(params),
         {:ok, result} <-
           CoordinatorAPI.post_message(project_id, %{
             text: text,
             source: source,
             message_id: message_id
           }) do
      conn
      |> put_status(:accepted)
      |> json(%{"message_id" => result.message_id, "seq" => result.seq})
    else
      {:error, reason} -> error_response(conn, reason)
    end
  end

  def messages(conn, %{"id" => project_id} = params) do
    with {:ok, after_seq} <- int_param(params, "after", 0, 0, nil),
         {:ok, limit} <-
           int_param(
             params,
             "limit",
             CoordinatorAPI.default_limit(),
             1,
             CoordinatorAPI.max_limit()
           ),
         {:ok, wait_ms} <- int_param(params, "wait_ms", 0, 0, CoordinatorAPI.max_wait_ms()),
         {:ok, view} <-
           CoordinatorAPI.wait_page(project_id, [after: after_seq, limit: limit], wait_ms) do
      json(conn, view)
    else
      {:error, reason} -> error_response(conn, reason)
    end
  end

  def show(conn, %{"id" => project_id}) do
    case CoordinatorAPI.status_view(project_id) do
      {:ok, view} -> json(conn, view)
      {:error, reason} -> error_response(conn, reason)
    end
  end

  def restart(conn, %{"id" => project_id}) do
    case CoordinatorAPI.restart(project_id, "http") do
      {:ok, view} -> json(conn, view)
      {:error, reason} -> error_response(conn, reason)
    end
  end

  # ---------------------------------------------------------------- params

  defp text_param(%{"text" => text}) when is_binary(text) do
    if String.trim(text) == "", do: {:error, {:invalid, :text}}, else: {:ok, text}
  end

  defp text_param(_), do: {:error, {:invalid, :text}}

  defp source_param(%{"source" => source}) when source in @http_sources, do: {:ok, source}
  defp source_param(%{"source" => _}), do: {:error, {:invalid, :source}}
  defp source_param(_), do: {:ok, "http"}

  defp message_id_param(%{"message_id" => id}) when is_binary(id) do
    if String.trim(id) == "" or byte_size(id) > 128,
      do: {:error, {:invalid, :message_id}},
      else: {:ok, id}
  end

  defp message_id_param(%{"message_id" => _}), do: {:error, {:invalid, :message_id}}
  defp message_id_param(_), do: {:ok, nil}

  defp int_param(params, key, default, min, max) do
    case Map.fetch(params, key) do
      :error ->
        {:ok, default}

      {:ok, raw} when is_binary(raw) ->
        case Integer.parse(raw) do
          {n, ""} when n >= min and (is_nil(max) or n <= max) -> {:ok, n}
          _ -> {:error, {:invalid, key}}
        end

      {:ok, _} ->
        {:error, {:invalid, key}}
    end
  end

  # ---------------------------------------------------------------- errors

  defp error_response(conn, :project_not_found),
    do: render_error(conn, :not_found, "project_not_found", "project not found")

  defp error_response(conn, {:project_archived, id}),
    do: render_error(conn, :conflict, "project_archived", "project #{id} is archived")

  defp error_response(conn, {:message_too_large, bytes, max}),
    do:
      render_error(
        conn,
        :request_entity_too_large,
        "message_too_large",
        "message is #{bytes} bytes; max is #{max}"
      )

  defp error_response(conn, {:invalid, field}),
    do: render_error(conn, :unprocessable_entity, "invalid_#{field}", "invalid #{field}")

  defp render_error(conn, status, code, message) do
    conn |> put_status(status) |> json(%{"error" => code, "message" => message})
  end
end
