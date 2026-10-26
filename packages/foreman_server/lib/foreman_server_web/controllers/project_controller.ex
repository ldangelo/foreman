defmodule ForemanServerWeb.ProjectController do
  @moduledoc """
  Project read-model endpoint.

  `GET /api/projects/:id` returns the projected state for a single project.
  `GET /api/projects` returns the projected state for matching projects.
  `GET /api/projects/:id/settings` returns the typed settings and limits.
  `GET /api/projects/:id/context` returns the standing context an agent launched
  now would receive (`ForemanServer.ProjectContext.build/2`, read-only).
  `GET /api/projects/:id/repositories` returns the project's repositories, the
  synthesised primary (`"main"`) first (E12); project JSON carries the same list
  under `repositories`.
  `GET /api/projects/:id/schedules` returns the project's schedules (Scheduled-tab data).

  Both project reads redact `config.env` / `config.environment` values
  (`ForemanServer.ProjectSettings.public_view/1`).
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.{
    Overview,
    ProjectSettings,
    ProjectSettingsDTO,
    ProjectStore,
    ProjectionStore,
    Telemetry
  }

  alias ForemanServer.Schedule.DTO, as: ScheduleDTO

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
        |> json(%{
          project:
            projection
            |> ProjectSettings.public_view()
            |> with_attention()
            |> with_repositories(project_id)
            |> stringify_keys()
        })
    end
  end

  @doc "GET /api/projects/:id/settings: typed settings + limits + status (no env)."
  def settings(conn, %{"id" => project_id}) do
    started_at = System.monotonic_time()
    conn = maybe_echo_request_id(conn)

    case ProjectSettingsDTO.fetch(project_id) do
      :not_found ->
        Telemetry.project_read(duration_ms_since(started_at), %{
          project_id: project_id,
          outcome: :error,
          code: "not_found",
          retryable: false
        })

        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", reason: ":project_not_found"})

      {:ok, dto} ->
        Telemetry.project_read(duration_ms_since(started_at), %{
          project_id: project_id,
          outcome: :ok
        })

        conn |> put_status(:ok) |> json(dto)
    end
  end

  @doc "GET /api/projects/:id/context: the exact standing context a launch would inject."
  def context(conn, %{"id" => project_id}) do
    case ForemanServer.ProjectContext.build(project_id) do
      {:error, :project_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", reason: ":project_not_found"})

      {:ok, bundle} ->
        json(conn, %{
          project_id: project_id,
          system_text: bundle.system_text,
          bytes: bundle.bytes,
          sha256: bundle.sha256,
          sections: Enum.map(bundle.sections, &%{id: &1.id, bytes: byte_size(&1.body)}),
          truncated: bundle.truncated,
          redactions: bundle.redactions
        })
    end
  end

  @doc """
  GET /api/projects/:id/schedules: the project's non-deleted schedules as
  `Schedule.DTO`s with computed `next_fire_at`, plus whether the ticker is running.
  """
  def schedules(conn, %{"id" => project_id}) do
    case ProjectionStore.project_projection(project_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", reason: ":project_not_found"})

      _project ->
        conn
        |> put_status(:ok)
        |> json(%{
          ticker: ScheduleDTO.ticker_status(),
          schedules: ScheduleDTO.list(project_id)
        })
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
      views = Enum.map(visible_projects, &ProjectSettings.public_view/1)
      attention_fields = Overview.project_fields_many(views)

      Telemetry.project_list(duration_ms_since(started_at), total_count, %{outcome: :ok})

      conn
      |> put_resp_header("x-total-count", Integer.to_string(total_count))
      |> put_status(:ok)
      |> json(%{
        projects:
          [visible_projects, views, attention_fields]
          |> Enum.zip_with(fn [projection, view, attention] ->
            view
            |> Map.merge(attention)
            |> with_repositories(Map.get(projection, :project_id) || Map.get(projection, :id))
            |> stringify_keys()
          end),
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

  @doc "GET /api/projects/:id/repositories: primary (`main`) first, then attached repositories."
  def repositories(conn, %{"id" => project_id}) do
    case ProjectionStore.project_repositories(project_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", reason: ":project_not_found"})

      repos ->
        json(conn, %{project_id: project_id, repositories: stringify_keys(repos)})
    end
  end

  defp with_repositories(projection, project_id) when is_binary(project_id),
    do: Map.put(projection, :repositories, ProjectionStore.project_repositories(project_id) || [])

  defp with_repositories(projection, _project_id), do: projection

  # E7-S4: operator attention flag, computed per request (O(threads) per project).
  defp with_attention(projection), do: Map.merge(projection, Overview.project_fields(projection))

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
