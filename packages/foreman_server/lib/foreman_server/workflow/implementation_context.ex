defmodule ForemanServer.Workflow.ImplementationContext do
  @moduledoc """
  Computes the frozen, server-derived `implementation_context` that
  accompanies a `task.approve` payload.

  The context pins every runtime input the implementation skill needs
  to a value that was true at approval time:

    * `trd_path` — normalized project-relative TRD document path
    * `trd_path_argument` — JSON-quoted relative path used as the
      skill's single positional argument (Pi runs inside the pinned
      worktree, so the argument is project-relative)
    * `project_root` — canonical absolute path of the registered
      project root (symlinks resolved once via `lstat` walking)
    * `source_revision` — exact `git rev-parse --verify HEAD^{commit}`
      recorded when the operator approved the task
    * `implementation_key` — `<project_id> \0 <normalized_trd_path>`
      SHA-256, used by the admission control to single-flight the
      same project/TRD combination
    * `beads_database_path` — for `implement-trd-beads` only, the
      absolute path of the registered task provider's database; never
      rediscovered from the worktree

  All fields are reserved. They cannot be overridden by the operator
  payload, the workflow YAML context, or runtime contexts. Re-approval
  of the same `task_id` + `approval_id` reuses the persisted snapshot
  even if HEAD, the manifest, or the controller checkout later changes.

  Inputs that fail validation are rejected at the admission boundary
  so the failure mode is visible at approval rather than a misleading
  worktree failure mid-run.
  """

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TaskProvider.Registry

  @beads_workflow "implement-trd-beads"
  @max_symlink_depth 40

  @type build_input :: %{
          :project_id => String.t(),
          optional(:workflow_type) => String.t() | nil,
          optional(:trd_path) => String.t() | nil
        }

  @type t :: %__MODULE__{
          trd_path: String.t(),
          trd_path_argument: String.t(),
          project_root: String.t(),
          source_revision: String.t(),
          implementation_key: String.t(),
          beads_database_path: String.t() | nil
        }

  @enforce_keys [
    :trd_path,
    :trd_path_argument,
    :project_root,
    :source_revision,
    :implementation_key
  ]
  defstruct trd_path: nil,
            trd_path_argument: nil,
            project_root: nil,
            source_revision: nil,
            implementation_key: nil,
            beads_database_path: nil

  @doc "Returns true when the workflow selector requires a Beads database path."
  @spec beads_workflow?(String.t() | nil) :: boolean()
  def beads_workflow?(nil), do: false
  def beads_workflow?(workflow_type), do: workflow_type == @beads_workflow

  @doc """
  Compute the frozen implementation context for a task projection.

  Resolves the registered project root, normalizes the TRD path,
  requires a Git work tree, requires the TRD to be a regular file
  reachable from the canonical project root without following any
  further symlinks, requires the TRD to be a tracked regular blob at
  `<source_revision>:<relative_path>`, and computes the
  `implementation_key`.
  """
  @spec build(build_input() | map()) ::
          {:ok, t()} | {:error, {:implementation_context_failed, atom()}}
  def build(%{project_id: project_id} = input) when is_binary(project_id) and project_id != "" do
    workflow_type = Map.get(input, :workflow_type)
    trd_path = Map.get(input, :trd_path)

    with {:ok, project} <- fetch_project(project_id),
         {:ok, canonical_root} <- canonicalize_root(project),
         {:ok, normalized} <- normalize_trd_path(trd_path),
         {:ok, source_revision} <- resolve_source_revision(canonical_root),
         :ok <- assert_regular_file_under(canonical_root, normalized),
         :ok <- assert_tracked_regular_blob(source_revision, canonical_root, normalized),
         {:ok, key} <- implementation_key(project_id, normalized),
         {:ok, beads_db} <- beads_database_path_for(workflow_type, project_id) do
      {:ok,
       %__MODULE__{
         trd_path: normalized,
         trd_path_argument: Jason.encode!(normalized),
         project_root: canonical_root,
         source_revision: source_revision,
         implementation_key: key,
         beads_database_path: beads_db
       }}
    end
  end

  def build(_), do: {:error, {:implementation_context_failed, :project_id_missing}}

  @doc "Render the context as a payload map for inclusion in a snapshot."
  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{} = ctx) do
    payload = %{
      "trd_path" => ctx.trd_path,
      "trd_path_argument" => ctx.trd_path_argument,
      "project_root" => ctx.project_root,
      "source_revision" => ctx.source_revision,
      "implementation_key" => ctx.implementation_key
    }

    case ctx.beads_database_path do
      nil -> payload
      path -> Map.put(payload, "beads_database_path", path)
    end
  end

  @doc "Compute the `implementation_key` from `project_id` and normalized `trd_path`."
  @spec implementation_key(String.t(), String.t()) :: {:ok, String.t()}
  def implementation_key(project_id, normalized_trd_path)
      when is_binary(project_id) and is_binary(normalized_trd_path) do
    digest =
      :crypto.hash(:sha256, project_id <> "\0" <> normalized_trd_path)
      |> Base.encode16(case: :lower)

    {:ok, digest}
  end

  # ------------------------------------------------------------------
  # Validation helpers
  # ------------------------------------------------------------------

  defp fetch_project(project_id) do
    case ProjectionStore.project_projection(project_id) do
      nil -> {:error, {:implementation_context_failed, :project_not_found}}
      %{} = project -> {:ok, project}
    end
  end

  # Resolve the registered project root to its canonical absolute
  # path by walking each path component with `lstat/1` (so symlinks
  # in the root path itself — e.g. macOS `/tmp` → `/private/tmp` —
  # are followed, but no component is trusted beyond what `lstat`
  # reports). Once canonicalized, the root is the containment basis
  # for the TRD path.
  defp canonicalize_root(%{path: root}) when is_binary(root) and root != "" do
    expanded = Path.expand(root)

    cond do
      Path.type(expanded) != :absolute ->
        {:error, {:implementation_context_failed, :project_root_not_absolute}}

      true ->
        case Path.split(expanded) do
          ["/"] ->
            {:error, {:implementation_context_failed, :project_root_invalid}}

          ["/" | components] ->
            walk_root_components(components, "/", MapSet.new(), @max_symlink_depth, expanded)
        end
    end
  end

  defp canonicalize_root(_),
    do: {:error, {:implementation_context_failed, :project_root_missing}}

  # Walk each component of the project root, following any symlink
  # encountered. Bounded depth and a visited set bound recursion on
  # symlink cycles. Returns `{:ok, canonical}` on success; the
  # original `expanded` is passed through to ensure we only return
  # success when the full path resolves.
  defp walk_root_components([], built, _visited, _depth, _expanded), do: {:ok, built}

  defp walk_root_components(_components, _built, _visited, 0, _expanded), do: :error

  defp walk_root_components(_components, _built, visited, _depth, _expanded)
       when map_size(visited) > @max_symlink_depth,
       do: :error

  defp walk_root_components([component | rest], built, visited, depth, expanded) do
    tentative = join_absolute(built, component)

    if MapSet.member?(visited, tentative) do
      :error
    else
      case File.lstat(tentative) do
        {:ok, %File.Stat{type: :symlink}} ->
          follow_root_symlink(tentative, rest, MapSet.put(visited, tentative), depth, expanded)

        {:ok, %File.Stat{type: :directory}} ->
          walk_root_components(rest, tentative, visited, depth, expanded)

        _ ->
          :error
      end
    end
  end

  defp follow_root_symlink(tentative, rest, visited, depth, expanded) do
    case :file.read_link(tentative) do
      {:ok, target} ->
        abs_target =
          if Path.type(target) == :absolute do
            target
          else
            Path.join(Path.dirname(tentative), target)
          end

        case Path.split(abs_target) do
          ["/"] ->
            walk_root_components(rest, "/", visited, depth - 1, expanded)

          ["/" | abs_components] ->
            walk_root_components(abs_components ++ rest, "/", visited, depth - 1, expanded)

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp join_absolute("/", component), do: "/" <> component
  defp join_absolute(built, component), do: built <> "/" <> component

  defp normalize_trd_path(nil),
    do: {:error, {:implementation_context_failed, :trd_path_missing}}

  defp normalize_trd_path(path) when is_binary(path) do
    cond do
      path == "" -> {:error, {:implementation_context_failed, :trd_path_blank}}
      String.contains?(path, "\0") -> {:error, {:implementation_context_failed, :trd_path_invalid}}
      String.starts_with?(path, "/") -> {:error, {:implementation_context_failed, :trd_path_not_project_relative}}
      true ->
        case safe_relative(path) do
          {:ok, ""} -> {:error, {:implementation_context_failed, :trd_path_blank}}
          {:ok, relative} -> {:ok, relative}
          :error -> {:error, {:implementation_context_failed, :trd_path_not_project_relative}}
        end
    end
  end

  defp safe_relative(path) do
    cleaned = path |> Path.split() |> Enum.reject(&(&1 == "."))

    cond do
      cleaned == [] -> {:ok, ""}
      Enum.any?(cleaned, &(&1 == "..")) -> :error
      true -> {:ok, Enum.join(cleaned, "/")}
    end
  end

  # `git rev-parse --verify HEAD^{commit}` guarantees the resolved
  # object is a commit (rejects unborn HEAD, detached tags, etc.).
  # Accept both 40-char SHA-1 and 64-char SHA-256 object IDs — Git
  # supports both, and operators may legitimately use SHA-256 repos.
  defp resolve_source_revision(root) do
    case System.cmd(
           "git",
           ["-C", root, "rev-parse", "--verify", "HEAD^{commit}"],
           stderr_to_stdout: true
         ) do
      {revision, 0} ->
        stripped = String.trim(revision)

        if hex_revision?(stripped) do
          {:ok, stripped}
        else
          {:error, {:implementation_context_failed, :source_revision_invalid}}
        end

      {_output, _status} ->
        {:error, {:implementation_context_failed, :not_a_git_repo}}
    end
  end

  defp hex_revision?(revision) do
    String.length(revision) in [40, 64] and String.match?(revision, ~r/^[0-9a-f]+$/)
  end

  # Walk each component of the normalized TRD path under the
  # canonical root with `lstat/1`. Containment is structural: we
  # only advance by appending to the canonical root, never by
  # following symlinks, so the final path is guaranteed to be
  # under the canonical root. Each intermediate must be a directory;
  # the final component must be a regular file. Any symlink — in
  # any intermediate or the final — is rejected.
  defp assert_regular_file_under(canonical_root, normalized) do
    case Path.split(normalized) do
      [] -> {:error, {:implementation_context_failed, :trd_path_blank}}
      components -> walk_user_components(components, canonical_root, MapSet.new(), @max_symlink_depth)
    end
  end

  defp walk_user_components([], _root, _visited, _depth), do: :ok

  defp walk_user_components(_components, _root, _visited, 0), do:
    {:error, {:implementation_context_failed, :trd_path_too_deep}}

  defp walk_user_components([component], root, _visited, _depth) do
    absolute = join_absolute(root, component)

    case File.lstat(absolute) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:implementation_context_failed, :trd_path_is_symlink}}
      {:ok, %File.Stat{type: :directory}} -> {:error, {:implementation_context_failed, :trd_path_is_directory}}
      {:ok, %File.Stat{}} -> {:error, {:implementation_context_failed, :trd_path_not_regular_file}}
      _ -> {:error, {:implementation_context_failed, :trd_path_missing}}
    end
  end

  defp walk_user_components([component | rest], root, visited, depth) do
    absolute = join_absolute(root, component)

    if MapSet.member?(visited, absolute) do
      {:error, {:implementation_context_failed, :trd_path_symlink_cycle}}
    else
      case File.lstat(absolute) do
        {:ok, %File.Stat{type: :directory}} ->
          walk_user_components(rest, absolute, visited, depth)

        {:ok, %File.Stat{type: :symlink}} ->
          {:error, {:implementation_context_failed, :trd_path_is_symlink}}

        {:ok, %File.Stat{}} ->
          {:error, {:implementation_context_failed, :trd_path_intermediate_not_directory}}

        _ ->
          {:error, {:implementation_context_failed, :trd_path_missing}}
      end
    end
  end

  # `git cat-file -t` returns `"blob"` for symlinks (mode 120000) too,
  # so a symlink that resolves to a regular file on disk would pass
  # both the working-tree `File.regular?/1` check and the cat-file
  # type check. Use `git ls-tree` to inspect the actual tree entry
  # mode and only accept regular blobs (100644/100755).
  defp assert_tracked_regular_blob(source_revision, root, normalized) do
    case System.cmd(
           "git",
           ["-C", root, "ls-tree", source_revision, "--", normalized],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> List.first()
        |> case do
          nil ->
            {:error, {:implementation_context_failed, :trd_path_not_tracked_blob}}

          line ->
            case String.split(line, ~r/\s+/, parts: 4) do
              [mode, "blob", _object, _path] when mode in ~w(100644 100755) ->
                :ok

              ["120000", "blob", _object, _path] ->
                {:error, {:implementation_context_failed, :trd_path_is_symlink}}

              [_, "blob", _object, _path] ->
                {:error, {:implementation_context_failed, :trd_path_not_regular_blob}}

              _ ->
                {:error, {:implementation_context_failed, :trd_path_not_tracked_blob}}
            end
        end

      {_output, _status} ->
        {:error, {:implementation_context_failed, :trd_path_not_tracked_blob}}
    end
  end

  # Beads database comes from the registered task provider config; it
  # must already be absolute. We deliberately reject relative paths
  # rather than expand against the project root — the canonical DB
  # lives outside the worktree and its location is a deployment
  # decision made at registration time.
  defp beads_database_path_for(workflow_type, project_id) do
    if beads_workflow?(workflow_type) do
      case Registry.project_config(project_id) do
        {:ok, %{config: %{"database_path" => path}}}
        when is_binary(path) and path != "" ->
          if Path.type(path) == :absolute do
            {:ok, path}
          else
            {:error, {:implementation_context_failed, :beads_database_path_not_absolute}}
          end

        {:ok, %{config: %{database_path: path}}}
        when is_binary(path) and path != "" ->
          if Path.type(path) == :absolute do
            {:ok, path}
          else
            {:error, {:implementation_context_failed, :beads_database_path_not_absolute}}
          end

        {:ok, _} ->
          {:error, {:implementation_context_failed, :beads_database_path_missing}}

        {:error, _} ->
          {:error, {:implementation_context_failed, :beads_database_path_missing}}
      end
    else
      {:ok, nil}
    end
  end
end