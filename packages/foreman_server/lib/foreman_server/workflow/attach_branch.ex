defmodule ForemanServer.Workflow.AttachBranch do
  @moduledoc """
  Prepares the worktree of a FOLLOW-UP run (`Workflow.FollowUp`): a run that works on an existing
  branch, a PR's head, instead of cutting a new one.

  `prepare/4` makes the local branch equal to the remote tip (fetch, then create it or fast-forward
  it; a local branch with commits the remote lacks is refused, never merged or discarded, and so is
  a branch held by a dirty worktree) and decides where the run works:

    * the branch is checked out in a LINKED worktree (typically the PR's original run, kept by
      `cleanup: never`): `{:reuse, path}`. The run records and uses that worktree as it stands, which
      is also what lets a provider session keyed on the working directory resume.
    * the branch is checked out in the repository's MAIN worktree: refused (the operator's live
      checkout is never handed to an agent).
    * otherwise: `{:create, path}`, at `hint_path` when that original path is free (so the session's
      working directory is the same again), else at `default_path`.

  Pure git; the executor does the recording. Never forces anything.
  """

  alias ForemanServer.Exec.{Error, Git}
  alias ForemanServer.Exec.Worktree, as: GitWorktree

  @type plan :: %{mode: :reuse | :create, path: String.t(), tip: String.t()}

  @spec prepare(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, plan()} | {:error, term()}
  def prepare(repo_path, branch, remote, opts) do
    default_path = Keyword.fetch!(opts, :default_path)
    hint_path = Keyword.get(opts, :hint_path)

    with {:ok, tip} <- GitWorktree.sync_branch(repo_path, remote, branch),
         {:ok, [main | _] = worktrees} <- Git.worktree_list(repo_path) do
      case Enum.find(worktrees, &(&1.branch == branch)) do
        %{path: path} when path == main.path ->
          {:error, {:branch_in_main_worktree, branch}}

        %{path: path} ->
          {:ok, %{mode: :reuse, path: path, tip: tip}}

        nil ->
          {:ok, %{mode: :create, path: free_path(hint_path, default_path), tip: tip}}
      end
    else
      {:error, %Error{} = error} -> {:error, {:attach_failed, error.code, error.message}}
      {:error, _} = error -> error
    end
  end

  defp free_path(hint, default) when is_binary(hint) and hint != "" do
    if File.exists?(hint), do: default, else: hint
  end

  defp free_path(_hint, default), do: default
end
