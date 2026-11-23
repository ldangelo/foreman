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
  repo is returned relative to `repo_root`. Anything else — a path outside the
  repo, or a missing/non-binary root — returns `:outside_repo`.
  """
  @spec repo_relative(Path.t(), String.t() | nil) :: {:ok, String.t()} | :outside_repo
  def repo_relative(path, repo_root)

  def repo_relative(path, repo_root) when is_binary(path) and is_binary(repo_root) do
    expanded_root = Path.expand(repo_root)
    expanded_path = Path.expand(path)

    if String.starts_with?(expanded_path, expanded_root <> "/") do
      {:ok, Path.relative_to(expanded_path, expanded_root)}
    else
      :outside_repo
    end
  end

  def repo_relative(path, _repo_root) when is_binary(path) do
    case Path.type(path) do
      :relative -> {:ok, path}
      _ -> :outside_repo
    end
  end

  def repo_relative(_path, _repo_root), do: :outside_repo

  @doc """
  The `Artifact:` line for a PR body, or `""` when it cannot be made relative.
  """
  @spec artifact_line(String.t() | nil, String.t() | nil) :: String.t()
  def artifact_line(path, repo_root) when is_binary(path) do
    case repo_relative(path, repo_root) do
      {:ok, relative} -> "\nArtifact: #{relative}\n"
      :outside_repo -> ""
    end
  end

  def artifact_line(_path, _repo_root), do: ""

  @doc """
  Shortest leak-free form of a path for prose: a relative path passes through,
  an absolute one keeps only its basename behind an ellipsis.
  """
  @spec display_path(String.t()) :: String.t()
  def display_path(path) when is_binary(path) do
    case Path.type(path) do
      :relative -> path
      _ -> "…/" <> Path.basename(path)
    end
  end

  def display_path(_path), do: "path"
end
