defmodule ForemanServer.Workflow.PlanContext do
  @moduledoc """
  Deterministic planning-context derivation for `plan` workflow tasks, and
  discovery of the documents those phases produce.

  Computes the immutable `task` and `planning` blocks for the Foreman
  `# Context (JSON)` payload, plus the absolute project `working_directory`
  under which generated documents are written.

  The planning block carries NO document paths up front. Foreman does not
  tell the agent what to name its PRD or TRD and does not gate on a name it
  computed: `planning.prd_path` and `planning.trd_path` appear only once
  `discover_document/3` has found the document a phase actually wrote, and
  `capture_document/3` has recorded it. Presence therefore means "produced",
  never "expected". Captured paths are relative to the phase's working
  directory — the phase worktree when it has one, otherwise
  `working_directory` — which `RunExecutor` joins on in one place.

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

  # The two planning gates, and the directory each one discovers its
  # document in. Foreman used to compute the filename and require the agent
  # to reproduce it; that contract failed in three consecutive live runs
  # (run-d6cdefe69706087e6bce5b1a10b95384,
  # run-dda353905d237cfd2557a706dd930bdd,
  # run-3da49f9ed1ae01f932092b31335b5623). Agents are non-deterministic, so
  # the gate now asserts a shape Foreman can verify from git — "exactly one
  # new document under this directory" — instead of a string the agent has
  # to echo back.
  @document_dirs %{
    "planning.prd_path" => Path.join("docs", "PRD"),
    "planning.trd_path" => Path.join("docs", "TRD")
  }

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

  @doc """
  The directory a planning `requiredFile` gate discovers its document in,
  or `nil` when `key` is not a planning gate — every other `requiredFile`
  key still names a context value the executor resolves and checks.
  """
  @spec document_dir(term()) :: String.t() | nil
  def document_dir(key) when is_binary(key), do: Map.get(@document_dirs, key)
  def document_dir(_), do: nil

  @doc """
  Discover the document the phase's agent just produced under `docs_dir`,
  returned relative to `working_directory`.

  An agent may leave the document it wrote uncommitted or commit it — the
  ensemble skills commit — and both mean "this phase produced it". The
  phase worktree is created at `base_ref`, so the documents new in the
  phase are the union of

    * paths added in commits since `base_ref`, and
    * paths still untracked or added in the working tree,

  deduplicated, so a document that was committed and then touched again is
  one document rather than a spurious ambiguity. The pipeline already
  guarantees a clean tree when a phase starts (a dirty worktree HALTs the
  run), so nothing in that union predates the phase. That invariant — not a
  timestamp, not a filename pattern — is what makes the discovery
  deterministic. Edits and renames of documents that already existed at
  `base_ref` are deliberately not candidates: the gate exists to prove a
  NEW document was produced.

  Each outcome is its own error so "the agent wrote nothing" can never be
  confused with "the agent wrote several things", with "this directory is
  not a git repository", or with "Foreman does not know where the phase
  started":

    * `{:planning_document_absent, docs_dir, working_directory}`
    * `{:planning_document_ambiguous, docs_dir, candidates}` — names them
    * `{:planning_document_scan_failed, working_directory, status, output}`
    * `{:planning_document_base_unknown, docs_dir, working_directory}`

  A `base_ref` Foreman cannot supply is NOT "absent". Without it the
  committed half of the union is unreadable, and scanning only the working
  tree would go on reporting a committed document as nothing produced —
  the exact defect this union fixes
  (run-9ff0f0ffc7e5845265d0cdcf8eb0ac2d failed
  `{:planning_document_absent, "docs/PRD", …}` seconds after its agent
  committed the PRD).
  """
  @spec discover_document(Path.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def discover_document(working_directory, docs_dir, base_ref)
      when is_binary(working_directory) and is_binary(docs_dir) and is_binary(base_ref) and
             base_ref != "" do
    with {:ok, committed} <- committed_paths(working_directory, docs_dir, base_ref),
         {:ok, uncommitted} <- working_tree_paths(working_directory, docs_dir) do
      case Enum.uniq(committed ++ uncommitted) do
        [path] ->
          {:ok, path}

        [] ->
          {:error, {:planning_document_absent, docs_dir, working_directory}}

        candidates ->
          {:error, {:planning_document_ambiguous, docs_dir, Enum.sort(candidates)}}
      end
    end
  end

  def discover_document(working_directory, docs_dir, base_ref)
      when is_binary(working_directory) and is_binary(docs_dir) and
             (is_nil(base_ref) or base_ref == "") do
    {:error, {:planning_document_base_unknown, docs_dir, working_directory}}
  end

  @doc """
  Record the document a phase produced, so the next phase reads the real
  path under `key` rather than one Foreman guessed. `plan.yaml`'s
  `create-trd` phase consumes the captured `planning.prd_path`.

  Capturing the PRD also re-keys `planning.correlation_id` onto the
  document that exists. PRD<->TRD pairing rides on the id embedded in the
  filename, and the agent mints its own, so the run-derived id would pair
  the TRD with a PRD that was never written. A captured filename carrying
  no id leaves nothing to pair on, so the stale id is dropped rather than
  kept as a plausible-looking wrong answer.
  """
  @spec capture_document(map(), String.t(), String.t()) :: map()
  def capture_document(plan_context, "planning." <> field, relative_path)
      when is_map(plan_context) and is_binary(relative_path) do
    planning =
      (Map.get(plan_context, "planning") || %{})
      |> Map.put(field, relative_path)
      |> adopt_correlation_id(field, relative_path)

    Map.put(plan_context, "planning", planning)
  end

  ## Private

  # Documents the agent COMMITTED. The phase worktree is created at
  # `base_ref`, so `--diff-filter=A` between it and `HEAD` is exactly "a
  # path this phase added": an edit to a document that already existed
  # reports M and a rename of one reports R, neither of which the gate
  # counts. `--find-renames` asks for that rename pairing explicitly
  # instead of inheriting the operator's `diff.renames`, under which a
  # renamed pre-existing document would otherwise surface as an addition.
  # `-z` emits the paths verbatim, so a name carrying a quote or a newline
  # arrives intact rather than git-quoted. The two revisions are separate
  # argv entries so a malformed `base_ref` fails as an unreadable revision
  # instead of being concatenated into some other range.
  defp committed_paths(working_directory, docs_dir, base_ref) do
    args = [
      "-C",
      working_directory,
      "diff",
      "--name-only",
      "-z",
      "--diff-filter=A",
      "--find-renames",
      base_ref,
      "HEAD",
      "--",
      docs_dir
    ]

    with {:ok, output} <- git_scan(working_directory, args) do
      {:ok, String.split(output, <<0>>, trim: true)}
    end
  end

  # Documents the agent left in the working tree, committing nothing.
  defp working_tree_paths(working_directory, docs_dir) do
    args = [
      "-C",
      working_directory,
      "status",
      "--porcelain",
      "-z",
      "--untracked-files=all",
      "--",
      docs_dir
    ]

    with {:ok, output} <- git_scan(working_directory, args) do
      {:ok, output |> String.split(<<0>>, trim: true) |> new_paths()}
    end
  end

  defp git_scan(working_directory, args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, output}

      {output, status} ->
        {:error, {:planning_document_scan_failed, working_directory, status, String.trim(output)}}
    end
  end

  # `git status --porcelain -z` emits one NUL-terminated `XY <path>` field
  # per entry, and follows a rename/copy entry with a second field carrying
  # the origin path. `-z` is what keeps a path containing a quote or a
  # newline from arriving mangled. Untracked (`?`) and added (`A`) are the
  # new documents; a rename is a move of one that already existed, so it is
  # skipped along with the extra field it drags behind it.
  defp new_paths([]), do: []

  defp new_paths([<<x::binary-size(1), _y::binary-size(1), " ", path::binary>> | rest]) do
    cond do
      x in ["R", "C"] -> new_paths(Enum.drop(rest, 1))
      x in ["?", "A"] -> [path | new_paths(rest)]
      true -> new_paths(rest)
    end
  end

  defp new_paths([_unparsable | rest]), do: new_paths(rest)

  # Only the PRD re-keys the pair; the TRD is the document being paired to
  # it. A basename that does not carry an id yields no pairing key at all,
  # which is the honest answer — the run-derived id is not it.
  defp adopt_correlation_id(planning, "prd_path", relative_path) do
    case Regex.run(~r/^PRD-\d{4}-([0-9A-Za-z]+)-/, Path.basename(relative_path)) do
      [_match, correlation_id] -> Map.put(planning, "correlation_id", correlation_id)
      nil -> Map.delete(planning, "correlation_id")
    end
  end

  defp adopt_correlation_id(planning, _field, _relative_path), do: planning

  defp task_type(task_projection) do
    Map.get(task_projection, :task_type) || Map.get(task_projection, "task_type") ||
      Map.get(task_projection, :type) || Map.get(task_projection, "type") || ""
  end

  # Which workflow the run executes. Three carriers, in descending order of
  # authority:
  #
  #   1. `workflow_snapshot.workflow_name` — the manifest name frozen at
  #      approval by `Approval.resolve_workflow_snapshot/2`.
  #   2. `workflow_snapshot.workflow` — the same value in the historical
  #      `work.submit` snapshot (retained for replay of pre-unification
  #      `WorkSubmitted` events; the live ingress no longer exists).
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
         # No `prd_path`/`trd_path`: nothing here names a document that
         # does not exist yet. `capture_document/3` adds each one after
         # `discover_document/3` proves the phase produced it.
         "planning" => %{
           "document_year" => document_year,
           "correlation_id" => correlation_id,
           "slug" => slug
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
