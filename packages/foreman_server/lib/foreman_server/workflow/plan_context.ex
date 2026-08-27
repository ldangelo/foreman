defmodule ForemanServer.Workflow.PlanContext do
  @moduledoc """
  Deterministic planning-context derivation for `plan` workflow tasks.

  Computes the immutable `task` and `planning` blocks for the Foreman
  `# Context (JSON)` payload, plus the absolute project `working_directory`
  under which generated documents are written.

  `planning.prd_path` and `planning.trd_path` are project-relative
  (`docs/PRD/PRD-<year>-<correlation_id>-<slug>.md`). The phase's working
  directory — the phase worktree when it has one, otherwise
  `working_directory` — is joined on by `RunExecutor` at dispatch time.

  All fields are derived from authoritative, server-owned data
  (`task_projection`, `project_projection`, `run_id`, frozen
  `approved_at`). User-supplied content (title, description) is treated as
  requirements content only — never as a path separator or command name.

  Applicability is decided by the workflow the run executes, not by the
  issue tracker's `task_type`: `plan` is not a legal Beads issue type
  (`task|bug|feature|epic|chore|docs|question`), so a beads-backed plan run
  necessarily carries a domain type such as `"feature"` while its
  `workflow_type` — or its frozen snapshot's workflow name — says `plan`.

  Returns `{:ok, context_map}` for plan-workflow runs whose project
  projection exposes a non-empty existing directory. Returns
  `{:error, reason}` for missing or invalid inputs so the caller can fail
  the run before the first phase. Returns `{:not_applicable, %{}}` for every
  other workflow so callers preserve current fallback behaviour.
  """

  alias ForemanServer.ProjectionStore

  # `plan` is the only bundled manifest whose phases gate on the `planning`
  # block (`priv/defaults/workflows/plan.yaml`: `requiredFile:
  # planning.prd_path` and `planning.trd_path`).
  @plan_workflow "plan"

  @doc """
  Build the planning context for `task_projection`. Runs that do not execute
  the `plan` workflow return `{:not_applicable, %{}}` so callers can
  short-circuit cleanly.
  """
  @spec build(map()) ::
          {:ok, map()} | {:not_applicable, %{}} | {:error, term()}
  def build(task_projection) when is_map(task_projection) do
    if plan_workflow?(task_projection) do
      build_plan_context(task_projection)
    else
      {:not_applicable, %{}}
    end
  end

  def build(_), do: {:not_applicable, %{}}

  @doc """
  Return `true` when the run described by `task_projection` executes the
  `plan` workflow, and therefore needs a `planning` block. Exposed so
  executors can decide whether to require a project path before phase 0.

  Legacy tasks registered with `task_type: "plan"` — the shape
  `Approval.prepare/2` still resolves the plan manifest from when no
  `workflow_type` is present — keep matching, but the workflow check alone
  is sufficient.
  """
  @spec plan_workflow?(map()) :: boolean()
  def plan_workflow?(task_projection) when is_map(task_projection) do
    workflow_name(task_projection) == @plan_workflow or
      task_type(task_projection) == @plan_workflow
  end

  def plan_workflow?(_), do: false

  ## Private

  defp task_type(task_projection) do
    Map.get(task_projection, :task_type) || Map.get(task_projection, "task_type") ||
      Map.get(task_projection, :type) || Map.get(task_projection, "type") || ""
  end

  # Which workflow the run executes. Three carriers, in descending order of
  # authority:
  #
  #   1. `workflow_snapshot.workflow_name` — the manifest name frozen at
  #      approval by `Approval.resolve_workflow_snapshot/2`.
  #   2. `workflow_snapshot.workflow` — the same value in the `work.submit`
  #      snapshot built by `Work.Submission.build_snapshot/4`.
  #   3. `workflow_type` / `workflow_name` on the projection itself — the
  #      registration-time selector (`TaskCreated.workflow_type`) that
  #      `Approval.prepare/2` resolves the manifest from, and the only
  #      carrier present before approval freezes a snapshot.
  #
  # The snapshot round-trips through JSON on its domain event, so its keys
  # arrive as strings while the projection around it uses atoms; both are
  # read for the same reason `task_type/1` reads both. Non-binary values are
  # skipped instead of short-circuiting the chain, so a malformed carrier
  # cannot hide a well-formed one below it.
  defp workflow_name(task_projection) do
    snapshot = workflow_snapshot(task_projection)

    workflow_binary(Map.get(snapshot, :workflow_name)) ||
      workflow_binary(Map.get(snapshot, "workflow_name")) ||
      workflow_binary(Map.get(snapshot, :workflow)) ||
      workflow_binary(Map.get(snapshot, "workflow")) ||
      workflow_binary(Map.get(task_projection, :workflow_type)) ||
      workflow_binary(Map.get(task_projection, "workflow_type")) ||
      workflow_binary(Map.get(task_projection, :workflow_name)) ||
      workflow_binary(Map.get(task_projection, "workflow_name")) ||
      ""
  end

  defp workflow_snapshot(task_projection) do
    case Map.get(task_projection, :workflow_snapshot) ||
           Map.get(task_projection, "workflow_snapshot") do
      %{} = snapshot -> snapshot
      _ -> %{}
    end
  end

  defp workflow_binary(value) when is_binary(value), do: value
  defp workflow_binary(_), do: nil

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
           "prd_path" => prd_path(slug, document_year, correlation_id),
           "trd_path" => trd_path(slug, document_year, correlation_id)
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
      is_struct(raw, DateTime) ->
        {:ok, raw.year}

      is_binary(raw) ->
        case DateTime.from_iso8601(raw) do
          {:ok, dt, _offset} -> {:ok, dt.year}
          _ -> {:error, :approved_at_invalid}
        end

      true ->
        {:error, :approved_at_invalid}
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
      sanitized != "" ->
        {:ok, cap_slug(sanitized)}

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
      not is_binary(title) ->
        {:error, :title_missing}

      title == "" ->
        {:error, :title_missing}

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

  # Planning document paths are RELATIVE to the phase's working directory,
  # never rooted here. A plan phase runs in a per-phase worktree, so the
  # absolute location is only knowable at dispatch time: joining the
  # project root here produced a path under the main checkout while the
  # agent wrote inside the worktree, and the `requiredFile` gate then
  # failed on a document the agent had written correctly. `RunExecutor`
  # joins these onto the phase cwd in exactly one place
  # (`resolve_phase_path/3`), which is also the value it exports as
  # `FOREMAN_PRD_PATH`/`FOREMAN_TRD_PATH` — one expression, so the path
  # the agent is told to write and the path Foreman checks cannot drift.
  defp prd_path(slug, year, correlation_id) do
    Path.join(["docs", "PRD", "PRD-#{year}-#{correlation_id}-#{slug}.md"])
  end

  defp trd_path(slug, year, correlation_id) do
    Path.join(["docs", "TRD", "TRD-#{year}-#{correlation_id}-#{slug}.md"])
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
