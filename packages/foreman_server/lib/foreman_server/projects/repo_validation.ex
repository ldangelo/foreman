defmodule ForemanServer.Projects.RepoValidation do
  @moduledoc """
  Validation of project repository identities and checkout paths (E12).

  One module, two halves:

    * **Pure** (`validate_id/1`, `validate_path/1`, `reject_duplicate_path/2`,
      `normalize_remote/1`) -- no I/O. `Aggregates.Project` calls these from
      `project.repo.add` and from `project.update` when it carries a `path`.
    * **Impure** (`inspect_checkout/1`, `check_candidate/3`) -- realpath, git
      work-tree probe, `origin` URL. These must NEVER run inside an aggregate;
      they belong in the `CommandGateway` side-effect step before dispatch.

  ## Seam for E12-S2

  `check_candidate/3` is the single entry point the gateway wires for BOTH
  `project.repo.add` (new repository) and `project.update` with a changed
  primary `path` (`replacing: "main"`). It canonicalises the candidate and
  returns the canonical path, which the gateway MUST substitute into the
  command payload before dispatch so the aggregate's pure uniqueness check
  compares canonical paths (a symlink cannot alias a repository). Nothing
  calls it yet: S1 only supplies the pure aggregate half.
  """

  @id_regex ~r/^[a-z0-9][a-z0-9-]{0,31}$/
  @primary_id "main"

  @type repo :: %{
          required(:id) => String.t(),
          required(:path) => String.t(),
          optional(any()) => any()
        }

  @doc "The reserved id of the synthesised primary repository (the project's `path`)."
  @spec primary_id() :: String.t()
  def primary_id, do: @primary_id

  @doc "Validate a repository id against `^[a-z0-9][a-z0-9-]{0,31}$`."
  @spec validate_id(term()) :: :ok | {:error, {:invalid_repo_id, term()}}
  def validate_id(id) when is_binary(id) do
    if Regex.match?(@id_regex, id), do: :ok, else: {:error, {:invalid_repo_id, id}}
  end

  def validate_id(id), do: {:error, {:invalid_repo_id, id}}

  @doc "A repository path must be an absolute binary."
  @spec validate_path(term()) :: :ok | {:error, {:repo_path_not_absolute, term()}}
  def validate_path(path) when is_binary(path) and path != "" do
    if Path.type(path) == :absolute, do: :ok, else: {:error, {:repo_path_not_absolute, path}}
  end

  def validate_path(path), do: {:error, {:repo_path_not_absolute, path}}

  @doc """
  Reject a `path` equal to any entry's path (primary and extras alike).
  Paths are compared after `Path.expand/1`; realpath canonicalisation is the
  gateway's job (`check_candidate/3`).
  """
  @spec reject_duplicate_path(String.t(), [String.t()]) ::
          :ok | {:error, {:repo_path_duplicate, String.t()}}
  def reject_duplicate_path(path, other_paths) do
    expanded = Path.expand(path)

    if Enum.any?(other_paths, &(is_binary(&1) and Path.expand(&1) == expanded)) do
      {:error, {:repo_path_duplicate, path}}
    else
      :ok
    end
  end

  @doc """
  Normalise a git remote URL for identity comparison: scheme, userinfo, a
  trailing `.git` and slashes are dropped and the rest lower-cased, so
  `git@github.com:Org/Repo.git` equals `https://github.com/org/repo`.
  """
  @spec normalize_remote(String.t()) :: String.t()
  def normalize_remote(url) when is_binary(url) do
    url
    |> String.trim()
    |> String.replace(~r{^[a-z+]+://}i, "")
    |> String.replace(~r{^[^@/]+@}, "")
    |> String.replace(~r{^([^/:]+):(?!\d+/)}, "\\1/")
    |> String.trim_trailing("/")
    |> String.replace_suffix(".git", "")
    |> String.downcase()
  end

  @doc """
  IMPURE. Canonicalise `path` (realpath, symlinks resolved) and probe it:
  it must exist and be a git work tree. Returns the canonical path and the
  normalised `origin` URL (nil when there is no `origin`).
  """
  @spec inspect_checkout(String.t()) ::
          {:ok, %{path: String.t(), remote: String.t() | nil}}
          | {:error, {:repo_path_not_found, String.t()} | {:repo_not_git_work_tree, String.t()}}
  def inspect_checkout(path) when is_binary(path) do
    with {:ok, real} <- realpath(path),
         true <- File.dir?(real) || {:error, {:repo_path_not_found, path}},
         :ok <- require_work_tree(real, path) do
      {:ok, %{path: real, remote: origin(real)}}
    end
  end

  @doc """
  IMPURE. Full candidate check for `project.repo.add` and `project.update`
  with a new `path`. `repos` is `ProjectionStore.project_repositories/1`
  (synthesised primary first). `opts[:replacing]` names the repository whose
  path the candidate replaces (`"main"` for `project.update`); it is excluded
  from the duplicate comparisons.

  Order: shape, realpath + work-tree probe, canonical path uniqueness, then
  remote identity (`{:repo_remote_duplicate, other_id}`). Returns the
  canonical path to substitute into the command.
  """
  @spec check_candidate(String.t(), [repo()], keyword()) ::
          {:ok, %{path: String.t(), remote: String.t() | nil}} | {:error, term()}
  def check_candidate(path, repos, opts \\ []) when is_list(repos) do
    replacing = Keyword.get(opts, :replacing)
    others = Enum.reject(repos, &(&1.id == replacing))

    with :ok <- validate_path(path),
         {:ok, info} <- inspect_checkout(path),
         :ok <- reject_duplicate_path(info.path, canonical_paths(others)),
         :ok <- reject_remote_duplicate(info.remote, others) do
      {:ok, info}
    end
  end

  defp canonical_paths(repos) do
    Enum.map(repos, fn %{path: path} ->
      case realpath(path) do
        {:ok, real} -> real
        _ -> path
      end
    end)
  end

  defp reject_remote_duplicate(nil, _others), do: :ok

  defp reject_remote_duplicate(remote, others) do
    Enum.find_value(others, :ok, fn %{id: id, path: path} ->
      case realpath(path) do
        {:ok, real} -> if origin(real) == remote, do: {:error, {:repo_remote_duplicate, id}}
        _ -> nil
      end
    end)
  end

  # The path must be the ROOT of a work tree, not a subdirectory of one:
  # worktrees are cut from the repository root.
  defp require_work_tree(real, original) do
    case System.cmd("git", ["-C", real, "rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {out, 0} -> if String.trim(out) == real, do: :ok, else: not_work_tree(original)
      _ -> not_work_tree(original)
    end
  rescue
    ErlangError -> not_work_tree(original)
  end

  defp not_work_tree(original), do: {:error, {:repo_not_git_work_tree, original}}

  defp origin(real) do
    case System.cmd("git", ["-C", real, "remote", "get-url", "origin"], stderr_to_stdout: true) do
      {url, 0} -> normalize_remote(url)
      _ -> nil
    end
  rescue
    ErlangError -> nil
  end

  @doc """
  IMPURE. The canonical `realpath` of `path` (every symlink component
  resolved, `..` normalised). `{:error, {:repo_path_not_found, component}}`
  when a component does not exist or the symlinks loop.
  """
  @spec canonical_path(String.t()) :: {:ok, String.t()} | {:error, term()}
  def canonical_path(path) when is_binary(path), do: realpath(path)

  # Resolves every symlink component (bounded, so a loop errors instead of
  # hanging). Errors with :repo_path_not_found when a component is missing.
  defp realpath(path), do: resolve(Path.split(Path.expand(path)), "", 0)

  defp resolve(_segments, _acc, depth) when depth > 40,
    do: {:error, {:repo_path_not_found, "symlink loop"}}

  defp resolve([], acc, _depth), do: {:ok, acc}
  defp resolve(["/" | rest], _acc, depth), do: resolve(rest, "/", depth)

  defp resolve([segment | rest], acc, depth) do
    candidate = Path.join(acc, segment)

    case File.read_link(candidate) do
      {:ok, target} ->
        resolve(Path.split(Path.expand(target, acc)) ++ rest, "", depth + 1)

      {:error, :einval} ->
        resolve(rest, candidate, depth)

      {:error, _} ->
        {:error, {:repo_path_not_found, candidate}}
    end
  end
end
