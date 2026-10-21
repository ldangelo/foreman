defmodule ForemanServer.Workflow.RunWorktreeLayout do
  @moduledoc """
  Pure arithmetic for where a run's worktrees live and what they are called.

  Extracted from `RunExecutor` because three callers need the same answers
  without an executor state: the executor itself, a mid-run repository attach
  (E12-S10) and a per-repository PR retry (E12-S6), where the executor process
  is already gone.

  Layout (one directory per run, rooted at `~/.foreman/worktrees`):

    * primary repository: `<root>/<project>/<task>/<run>/<leaf>` (`leaf`
      defaults to `workspace` and is declared by the workflow's `worktree:
      path:`) - unchanged from the single-repository layout;
    * secondary repository: `<root>/<project>/<task>/<run>/repos/<repo_id>`.

  Secondary worktrees are siblings of the primary leaf, not children of it, so
  `git status` / `.gitignore` in the primary checkout are unaffected. Every
  path is contained by `<root>/<project>/<task>/<run>/` (`contained?/4`).

  The branch is the same rendered name in every repository: branch namespaces
  are per repository, and one name makes the per-repository PRs easy to
  correlate.
  """

  alias ForemanServer.Workflow.Worktree

  @default_leaf "workspace"
  @default_branch_template "foreman/{task_id}/{run_id}"

  @typedoc "Which of a run's repositories a path is for."
  @type repo_role :: :primary | {:secondary, String.t()}

  @doc "Root directory every run worktree lives under."
  @spec base_root() :: String.t()
  def base_root, do: Path.join([System.user_home!(), ".foreman", "worktrees"])

  @doc "The run's own directory, which contains every one of its worktrees."
  @spec run_root(String.t(), String.t(), String.t()) :: String.t()
  def run_root(project_id, task_id, run_id),
    do: Path.join([base_root(), project_id, task_id, run_id])

  @doc """
  Worktree path for one repository of a run.

  `leaf` is the already-rendered primary leaf directory (`nil` means the
  default `workspace`); a secondary repository ignores it.
  """
  @spec path(String.t(), String.t(), String.t(), repo_role(), String.t() | nil) :: String.t()
  def path(project_id, task_id, run_id, role, leaf \\ nil)

  def path(project_id, task_id, run_id, :primary, leaf) do
    Path.join(run_root(project_id, task_id, run_id), leaf || @default_leaf)
  end

  def path(project_id, task_id, run_id, {:secondary, repo_id}, _leaf) when is_binary(repo_id) do
    Path.join([run_root(project_id, task_id, run_id), "repos", repo_id])
  end

  @doc """
  The run's branch name: the workflow's `worktree: branch:` or the default
  `foreman/{task_id}/{run_id}`, rendered. The same name is used in every
  repository of the run.
  """
  @spec branch(map(), String.t(), String.t()) :: String.t()
  def branch(spec, task_id, run_id) do
    template =
      case Map.get(spec, :branch) do
        branch when is_binary(branch) and branch != "" -> branch
        _ -> @default_branch_template
      end

    render(template, task_id, run_id)
  end

  @doc "Substitutes the `{run_id}` and `{task_id}` placeholders of a worktree template."
  @spec render(String.t(), String.t(), String.t()) :: String.t()
  def render(template, task_id, run_id) do
    template
    |> String.replace("{run_id}", run_id)
    |> String.replace("{task_id}", task_id)
  end

  @doc """
  Correlation id of a run's worktree for one repository (`nil` = the run's
  primary: `wt-<run_id>`; otherwise `wt-<run_id>-<repo_id>`).
  """
  @spec operation_id(String.t(), String.t() | nil) :: String.t()
  def operation_id(run_id, repo_id), do: Worktree.operation_id(run_id, repo_id)

  @doc """
  Whether `worktree_path` resolves under the run's own directory. Guards
  against templates that smuggle `..` segments or render absolute paths.
  """
  @spec contained?(String.t(), String.t(), String.t(), String.t()) :: boolean()
  def contained?(project_id, task_id, run_id, worktree_path) do
    expected_root = project_id |> run_root(task_id, run_id) |> Path.expand()
    actual_root = Path.expand(worktree_path)

    actual_root == expected_root or String.starts_with?(actual_root, expected_root <> "/")
  end
end
