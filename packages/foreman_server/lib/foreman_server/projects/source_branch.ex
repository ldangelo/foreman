defmodule ForemanServer.Projects.SourceBranch do
  @moduledoc """
  The branch of the session a continuation builds on (`adopt --continue --from-source-branch`): the new
  thread's worktree is cut from that branch instead of from the project's current branch, and it is the
  new thread's PR base (a run's PR base is the branch it was cut from, AGENTS.md).

  Read from the projections of the subject being continued, the way `ForkSource` reads its provider
  session:

    * a `run`: the branch of its primary worktree (`WorktreeCreated`);
    * a `task`: the same, for its most recently started run that has one;
    * a `jobsite`: the branch it works on (`JobsiteStarted`, `JobsiteWorktreeProvisioned`); a jobsite on
      the `head` strategy works in the repository's own checkout and has none.

  Nothing is guessed and nothing falls back to the project's current branch: the operator asked for the
  source's. Refusals are typed and say what is missing.

    * `{:source_branch_unknown, kind, id}` - the subject recorded no branch (a task that never ran, a
      jobsite on the head strategy, a run of a workflow that disables its worktree);
    * `{:source_branch_not_found, branch, repo_path}` - `branch` is not a local branch of `repo_path` (the
      repository the new worktree is cut from): deleted after a merge or by a worktree cleanup, or the
      session ran in another repository;
    * `{:invalid_source_branch, value}` - a branch name that is not safe to hand to git (`validate/1`).
  """

  alias ForemanServer.Jobsite.Git
  alias ForemanServer.ProjectionStore

  # The same shape `Jobsite.Spec` accepts for a branch strategy: it ends up as a git argument.
  @pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._\/-]*\z/

  @doc """
  Checks the branch recorded on a task (`TaskCreated.source_branch`): `:none` when it is absent, `:ok`
  for a branch name that is safe to hand to git, `{:error, {:invalid_source_branch, value}}` otherwise.
  """
  @spec validate(term()) :: :none | :ok | {:error, {:invalid_source_branch, term()}}
  def validate(nil), do: :none

  def validate(branch) when is_binary(branch) do
    if Regex.match?(@pattern, branch) and not String.contains?(branch, ["..", "//"]) and
         not String.ends_with?(branch, [".lock", "/", "."]),
       do: :ok,
       else: {:error, {:invalid_source_branch, branch}}
  end

  def validate(other), do: {:error, {:invalid_source_branch, other}}

  @doc "The branch `kind` (`run`, `task` or `jobsite`) `id` worked on, from the projections."
  @spec resolve(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, {:source_branch_unknown, String.t(), String.t()}}
  def resolve("run", id) when is_binary(id), do: id |> run_branch() |> checked("run", id)

  def resolve("task", id) when is_binary(id) do
    ProjectionStore.list_runs()
    |> Enum.filter(&(&1.task_id == id))
    |> Enum.sort_by(& &1.started_at_ms, :desc)
    |> Enum.find_value(&run_branch(&1.run_id))
    |> checked("task", id)
  end

  def resolve("jobsite", id) when is_binary(id) do
    case ProjectionStore.jobsite(id) do
      %{branch: branch} when is_binary(branch) and branch != "" -> {:ok, branch}
      _no_branch -> {:error, {:source_branch_unknown, "jobsite", id}}
    end
  end

  @doc "`:ok` when `branch` is a local branch of the repository at `repo_path`."
  @spec ensure_exists(String.t(), String.t() | nil) ::
          :ok | {:error, {:source_branch_not_found, String.t(), String.t() | nil}}
  def ensure_exists(branch, repo_path) when is_binary(branch) do
    if is_binary(repo_path) and Git.branch_exists?(repo_path, branch),
      do: :ok,
      else: {:error, {:source_branch_not_found, branch, repo_path}}
  end

  defp run_branch(run_id) do
    run_id
    |> ProjectionStore.worktrees_for_run()
    |> Enum.find_value(fn
      %{primary?: true, branch: branch} when is_binary(branch) and branch != "" -> branch
      _secondary_or_detached -> nil
    end)
  end

  defp checked(nil, kind, id), do: {:error, {:source_branch_unknown, kind, id}}
  defp checked(branch, _kind, _id), do: {:ok, branch}
end
