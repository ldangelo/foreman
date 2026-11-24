defmodule ForemanServer.Workflow.PrBodyPath do
  @moduledoc """
  Turns host-local paths into something safe to paste into a GitHub PR body.

  An artifact path or a review-finding path is an absolute path on the machine
  that produced it (`/Users/<user>/.foreman/worktrees/<project>/<run>/workspace/
  docs/reports/.../FIX_REPORT.md`). Once the worktree is cleaned up the path
  resolves to nothing, and the body has leaked the operator's home layout. The
  artifact is committed into the run branch, so the path relative to the repo
  root is the form that is both linkable and leak-free; a path outside the repo
  has no such form and is omitted or reduced to its basename.
  """

  @doc """
  Express `path` relative to `repo_root`.

  An already-relative path is returned unchanged. An absolute path inside the
  repo is returned relative to `repo_root`. A path outside the repo, or an
  absolute path with no root to compare it against, returns `:outside_repo`.

  A malformed path or root raises. A PR body that quietly drops the artifact
  because the producer passed nonsense is a lie, not a review.
  """
  @spec repo_relative(Path.t() | nil, String.t() | nil) :: {:ok, String.t()} | :outside_repo
  def repo_relative(path, repo_root)

  def repo_relative(path, repo_root) when is_binary(path) do
    trimmed = String.trim(path)

    if trimmed == "" do
      raise ArgumentError,
            "PrBodyPath.repo_relative/2 expects a path string or nil, got: #{inspect(path)}"
    end

    # Relative first, before expansion: `Path.expand/1` resolves a relative
    # path against the *server's* cwd, which would silently rebase
    # "lib/foo.ex" onto whatever directory the Phoenix process runs in.
    case Path.type(trimmed) do
      :relative -> {:ok, trimmed}
      :absolute -> relative_to_root(trimmed, repo_root)
      _ -> :outside_repo
    end
  end

  def repo_relative(nil, _repo_root), do: :outside_repo

  def repo_relative(path, _repo_root) do
    raise ArgumentError,
          "PrBodyPath.repo_relative/2 expects a path string or nil, got: #{inspect(path)}"
  end

  defp relative_to_root(_path, nil), do: :outside_repo

  defp relative_to_root(path, repo_root) when is_binary(repo_root) do
    root = String.trim(repo_root)

    if root == "" do
      raise ArgumentError,
            "PrBodyPath.repo_relative/2 expects a repository root path, got: #{inspect(repo_root)}"
    end

    expanded_root = Path.expand(root)
    expanded_path = Path.expand(path)

    if String.starts_with?(expanded_path, expanded_root <> "/") do
      {:ok, Path.relative_to(expanded_path, expanded_root)}
    else
      :outside_repo
    end
  end

  defp relative_to_root(_path, repo_root) do
    raise ArgumentError,
          "PrBodyPath.repo_relative/2 expects a repository root path or nil, got: #{inspect(repo_root)}"
  end

  @doc """
  The `Artifact:` line of a PR body, or `""` when the artifact cannot be made
  relative to the repository.
  """
  @spec artifact_line(String.t() | nil, String.t() | nil) :: String.t()
  def artifact_line(path, repo_root)

  def artifact_line(nil, _repo_root), do: ""

  def artifact_line(path, repo_root) when is_binary(path) do
    case repo_relative(path, repo_root) do
      {:ok, relative} -> "\nArtifact: #{relative}\n"
      :outside_repo -> ""
    end
  end

  def artifact_line(path, _repo_root) do
    raise ArgumentError,
          "PrBodyPath.artifact_line/2 expects a path string or nil, got: #{inspect(path)}"
  end

  @doc """
  The shortest leak-free form of a path for prose: a relative path passes
  through, an absolute one keeps only its basename behind an ellipsis.
  """
  @spec display_path(String.t()) :: String.t()
  def display_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    case Path.type(trimmed) do
      :relative -> trimmed
      _ -> "…/" <> Path.basename(trimmed)
    end
  end

  def display_path(path) do
    raise ArgumentError,
          "PrBodyPath.display_path/1 expects a path string, got: #{inspect(path)}"
  end
end
