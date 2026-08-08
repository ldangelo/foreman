defmodule ForemanServerWeb.ProjectController do
  @moduledoc """
  Project read-model endpoint.

  `GET /api/projects/:id` returns the projected state for a single project.
  `GET /api/projects` returns the projected state for matching projects.
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.{ProjectStore, Telemetry}

  @default_projects_list_max 1000

  def show(conn, %{"id" => project_id}) do
    started_at = System.monotonic_time()
    conn = maybe_echo_request_id(conn)

    case ProjectStore.get(project_id) do
      nil ->
        Telemetry.project_read(duration_ms_since(started_at), %{
          project_id: project_id,
          outcome: :error,
          code: "not_found",
          retryable: false
        })

        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", reason: ":project_not_found"})

      projection when is_map(projection) ->
        Telemetry.project_read(duration_ms_since(started_at), %{
          project_id: project_id,
          outcome: :ok
        })

        conn
        |> put_status(:ok)
        |> json(%{project: stringify_keys(projection)})
    end
  end

  def index(conn, params) do
    started_at = System.monotonic_time()
    conn = maybe_echo_request_id(conn)

    with {:ok, include_archived?} <- parse_include_archived(params),
         {:ok, limit} <- parse_limit(params) do
      projects =
        ProjectStore.list()
        |> Enum.reject(&(not include_archived? and archived_project?(&1)))

      total_count = length(projects)
      visible_projects = Enum.take(projects, limit)
      truncated? = total_count > length(visible_projects)

      Telemetry.project_list(duration_ms_since(started_at), total_count, %{outcome: :ok})

      conn
      |> put_resp_header("x-total-count", Integer.to_string(total_count))
      |> put_status(:ok)
      |> json(%{
        projects: Enum.map(visible_projects, &stringify_keys/1),
        meta: %{truncated: truncated?}
      })
    else
      {:error, :invalid_query} ->
        Telemetry.project_list(duration_ms_since(started_at), 0, %{
          outcome: :error,
          code: "invalid_query",
          retryable: false
        })

        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_query", reason: ":invalid_query"})
    end
  end

  defp parse_include_archived(%{"include_archived" => value}) when is_binary(value) do
    case value do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:error, :invalid_query}
    end
  end

  defp parse_include_archived(_), do: {:ok, false}

  defp parse_limit(%{"limit" => value}) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 ->
        {:ok, min(parsed, projects_list_max())}

      _ ->
        {:error, :invalid_query}
    end
  end

  defp parse_limit(_), do: {:ok, projects_list_max()}

  defp projects_list_max do
    Application.get_env(:foreman_server, :projects_list_max, @default_projects_list_max)
  end

  defp archived_project?(projection) when is_map(projection) do
    Map.get(projection, :archived?) == true or Map.get(projection, "archived") == true
  end

  defp archived_project?(_), do: false

  defp duration_ms_since(started_at) do
    System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)
  end

  defp maybe_echo_request_id(conn) do
    case get_req_header(conn, "x-request-id") do
      [request_id | _] -> put_resp_header(conn, "x-request-id", request_id)
      [] -> conn
    end
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
