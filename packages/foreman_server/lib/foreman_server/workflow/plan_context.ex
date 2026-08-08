defmodule ForemanServer.Workflow.PlanContext do
  @moduledoc """
  Deterministic planning-context derivation for `plan` workflow tasks.

  Computes the immutable `task` and `planning` blocks for the Foreman
  `# Context (JSON)` payload, plus the absolute project `working_directory`
  under which generated documents are written.

  All fields are derived from authoritative, server-owned data
  (`task_projection`, `project_projection`, `run_id`, frozen
  `approved_at`). User-supplied content (title, description) is treated as
  requirements content only — never as a path separator or command name.

  Returns `{:ok, context_map}` for `plan` tasks whose project projection
  exposes a non-empty existing directory. Returns `{:error, reason}` for
  missing or invalid inputs so the caller can fail the run before the
  first phase. Returns `{:not_applicable, %{}}` for non-plan tasks so
  callers preserve current fallback behaviour.
  """

  alias ForemanServer.ProjectionStore

  @doc """
  Build the planning context for `task_projection`. Non-plan tasks return
  `{:not_applicable, %{}}` so callers can short-circuit cleanly.
  """
  @spec build(map()) ::
          {:ok, map()} | {:not_applicable, %{}} | {:error, term()}
  def build(task_projection) when is_map(task_projection) do
    case task_type(task_projection) do
      "plan" -> build_plan_context(task_projection)
      _other -> {:not_applicable, %{}}
    end
  end

  def build(_), do: {:not_applicable, %{}}

  @doc """
  Return `true` when the task projection is a `plan` task. Exposed so
  executors can decide whether to require a project path before phase 0.
  """
  @spec plan_task?(map()) :: boolean()
  def plan_task?(task_projection) when is_map(task_projection),
    do: task_type(task_projection) == "plan"

  def plan_task?(_), do: false

  ## Private

  defp task_type(task_projection) do
    Map.get(task_projection, :task_type) || Map.get(task_projection, "task_type") ||
      Map.get(task_projection, :type) || Map.get(task_projection, "type") || ""
  end

  defp build_plan_context(task_projection) do
    with {:ok, project} <- fetch_project(task_projection),
         {:ok, project_path} <- require_existing_directory(project),
         {:ok, document_year} <- document_year(task_projection),
         {:ok, correlation_id} <- correlation_id(task_projection),
         {:ok, slug} <- slug(task_projection),
         {:ok, task_block} <- task_block(task_projection) do
      {:ok,
       %{
         "working_directory" => project_path,
         "task" => task_block,
         "planning" => %{
           "document_year" => document_year,
           "correlation_id" => correlation_id,
           "slug" => slug,
           "prd_path" => prd_path(project_path, slug, document_year, correlation_id),
           "trd_path" => trd_path(project_path, slug, document_year, correlation_id)
         }
       }}
    end
  end

  defp fetch_project(task_projection) do
    project_id = project_id_of(task_projection)

    if is_binary(project_id) and project_id != "" do
      case ProjectionStore.project_projection(project_id) do
        %{} = project -> {:ok, project}
        _ -> {:error, {:project_not_found, project_id}}
      end
    else
      {:error, :project_id_missing}
    end
  end

  defp require_existing_directory(project) do
    path = project_path_of(project)

    cond do
      not is_binary(path) -> {:error, :project_path_missing}
      path == "" -> {:error, :project_path_missing}
      not File.dir?(path) -> {:error, {:project_path_invalid, path}}
      true -> {:ok, path}
    end
  end

  defp document_year(task_projection) do
    raw = Map.get(task_projection, :approved_at) || Map.get(task_projection, "approved_at")

    cond do
      is_struct(raw, DateTime) -> {:ok, raw.year}
      is_binary(raw) ->
        case DateTime.from_iso8601(raw) do
          {:ok, dt, _offset} -> {:ok, dt.year}
          _ -> {:error, :approved_at_invalid}
        end
      true -> {:error, :approved_at_invalid}
    end
  end

  defp correlation_id(task_projection) do
    case run_id_of(task_projection) do
      "run-" <> rest when is_binary(rest) and byte_size(rest) >= 8 ->
        prefix = binary_part(rest, 0, 8)
        if String.match?(prefix, ~r/^[0-9a-f]{8}$/),
          do: {:ok, prefix},
          else: {:error, :run_id_invalid}

      _ ->
        {:error, :run_id_invalid}
    end
  end

  defp slug(task_projection) do
    sanitized = sanitize_slug(title_of(task_projection))

    cond do
      sanitized != "" -> {:ok, cap_slug(sanitized)}
      true ->
        case sanitized_fallback(task_id_of(task_projection)) do
          "" -> {:ok, "plan"}
          fallback -> {:ok, cap_slug(fallback)}
        end
    end
  end

  defp task_block(task_projection) do
    description =
      Map.get(task_projection, :description) || Map.get(task_projection, "description") || ""

    title = Map.get(task_projection, :title) || Map.get(task_projection, "title")

    cond do
      not is_binary(title) -> {:error, :title_missing}
      title == "" -> {:error, :title_missing}
      true ->
        {:ok,
         %{
           "id" => task_id_of(task_projection),
           "project_id" => project_id_of(task_projection),
           "type" => task_type(task_projection),
           "title" => title,
           "description" => description
         }}
    end
  end

  defp prd_path(project_path, slug, year, correlation_id) do
    Path.join([project_path, "docs", "PRD", "PRD-#{year}-#{correlation_id}-#{slug}.md"])
  end

  defp trd_path(project_path, slug, year, correlation_id) do
    Path.join([project_path, "docs", "TRD", "TRD-#{year}-#{correlation_id}-#{slug}.md"])
  end

  ## Field accessors (atom/string tolerant)

  defp project_id_of(task) do
    Map.get(task, :project_id) || Map.get(task, "project_id") || ""
  end

  defp task_id_of(task) do
    Map.get(task, :task_id) || Map.get(task, "task_id") ||
      Map.get(task, :id) || Map.get(task, "id") || ""
  end

  defp run_id_of(task) do
    Map.get(task, :run_id) || Map.get(task, "run_id") || ""
  end

  defp title_of(task) do
    Map.get(task, :title) || Map.get(task, "title") || ""
  end

  ## Project projection accessors

  defp project_path_of(project) do
    Map.get(project, :path) || Map.get(project, "path") || ""
  end

  ## Slug helpers

  defp sanitize_slug(raw) when is_binary(raw) do
    raw
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp sanitize_slug(_), do: ""

  defp cap_slug(slug) when is_binary(slug) and byte_size(slug) <= 48, do: slug

  defp cap_slug(slug) when is_binary(slug) do
    binary_part(slug, 0, 48) |> String.trim_trailing("-")
  end

  defp sanitized_fallback(id) when is_binary(id) do
    id
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp sanitized_fallback(_), do: ""
end