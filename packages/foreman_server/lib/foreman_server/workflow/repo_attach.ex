defmodule ForemanServer.Workflow.RepoAttach do
  @moduledoc """
  Attaches a registered repository of the run's project to a RUNNING run
  (E12 S10, S3 §12): creates that repository's worktree eagerly, through the
  same layout and `Worktree.create/1` the executor uses at run start.

  There is no "repo attached" event: the `WorktreeCreated` event carrying
  `repo_id` is the durable record, and the executor rebuilds `run_worktrees`
  from the run's worktree projection at every phase start, so the repository
  is part of the **next** phase's env (`FOREMAN_REPOS`), prompt assigns,
  commit and PR finalisation. The phase already running does not see it.

  Idempotent: a repository that already has a created worktree on the run
  returns `{:ok, :already_attached}` without touching git (the worktree
  operation id `wt-<run>-<repo>` is deterministic, but `git worktree add` is
  not, so the projection is consulted first).
  """

  alias ForemanServer.CommandGateway
  alias ForemanServer.Identity
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Workflow.{RunWorktreeLayout, Worktree}

  @type result :: {:ok, :attached | :already_attached} | {:error, term()}

  @doc """
  Attach `repo_id` (registered on the run's project, not the run's primary) to
  `run_id`.
  """
  @spec attach(String.t(), String.t()) :: result()
  def attach(run_id, repo_id) when is_binary(run_id) and is_binary(repo_id) do
    with {:ok, run} <- fetch_run(run_id),
         entries = ProjectionStore.worktrees_for_run(run_id),
         false <- attached?(entries, repo_id),
         {:ok, repo} <- fetch_repo(run.project_id, repo_id),
         {:ok, primary} <- fetch_primary_worktree(entries, run_id),
         {:ok, base_branch, base_ref} <- repo_base(repo) do
      create(run, run_id, repo, primary, base_branch, base_ref)
    else
      true -> {:ok, :already_attached}
      {:error, _} = error -> error
    end
  end

  defp create(run, run_id, repo, primary, base_branch, base_ref) do
    task_id = run.task_id || run_id
    project_id = run.project_id
    operation_id = RunWorktreeLayout.operation_id(run_id, repo.id)
    worktree_path = RunWorktreeLayout.path(project_id, task_id, run_id, {:secondary, repo.id})

    with true <-
           RunWorktreeLayout.contained?(project_id, task_id, run_id, worktree_path) ||
             {:error, {:worktree_path_escapes_run, worktree_path}},
         :ok <- File.mkdir_p(Path.dirname(worktree_path)),
         {:ok, ^worktree_path} <-
           Worktree.create(%{
             operation_id: operation_id,
             project_id: project_id,
             run_id: run_id,
             phase_id: phase_id(run, run_id),
             repo_path: repo.path,
             worktree_path: worktree_path,
             base_ref: base_ref,
             branch: primary.branch,
             repo_id: repo.id
           }) do
      # Best effort, like the executor's: the base is what makes the repo's PR
      # target resume-safe, and the command id is the executor's own, so a
      # later executor provisioning of the same repo dedupes.
      _ =
        CommandGateway.dispatch_system(%{
          type: "run.record_base_branch",
          command_id: "run_executor:base-branch:" <> run_id <> ":" <> repo.id,
          aggregate_id: "run:#{run_id}",
          payload: %{run_id: run_id, base_branch: base_branch, repo_id: repo.id}
        })

      {:ok, :attached}
    else
      {:ok, other_path} -> {:error, {:worktree_path_drift, worktree_path, other_path}}
      {:error, _} = error -> error
    end
  end

  defp fetch_run(run_id) do
    case ProjectionStore.run(run_id) do
      %{project_id: project_id} = run when is_binary(project_id) -> {:ok, run}
      _ -> {:error, {:not_found, :run, run_id}}
    end
  end

  defp attached?(entries, repo_id),
    do: Enum.any?(entries, &(&1.repo_id == repo_id and &1.status == "created"))

  defp fetch_repo(project_id, repo_id) do
    case ProjectionStore.project_repository(project_id, repo_id) do
      %{path: path} = repo when is_binary(path) -> {:ok, repo}
      _ -> {:error, {:unknown_repo, repo_id}}
    end
  end

  # The run's branch name is the primary worktree's: every repo of a run uses
  # the same one. A run with no primary worktree (a workflow with worktrees
  # disabled, or one that has not provisioned yet) has nothing to attach to.
  defp fetch_primary_worktree(entries, run_id) do
    case Enum.find(entries, &(is_nil(&1.repo_id) and &1.status == "created")) do
      %{branch: branch} = entry when is_binary(branch) and branch != "" -> {:ok, entry}
      _ -> {:error, {:run_has_no_worktree, run_id}}
    end
  end

  # The repository's registered `default_branch` when set (base_ref = its
  # tip), else the branch checked out right now with base_ref = HEAD: the same
  # rule the executor applies to a secondary at run start.
  defp repo_base(%{path: path, default_branch: default_branch}) do
    case default_branch do
      branch when is_binary(branch) and branch != "" ->
        with {:ok, sha} <- rev_parse(path, branch), do: {:ok, branch, sha}

      _ ->
        with {:ok, branch} <- checkout_branch(path),
             {:ok, sha} <- rev_parse(path, "HEAD") do
          {:ok, branch, sha}
        end
    end
  end

  defp checkout_branch(path) do
    case git(path, ["symbolic-ref", "--quiet", "--short", "HEAD"]) do
      {:ok, ""} -> {:error, {:checkout_branch_unresolvable, path, :detached_head}}
      {:ok, branch} -> {:ok, branch}
      {:error, detail} -> {:error, {:checkout_branch_unresolvable, path, detail}}
    end
  end

  defp rev_parse(path, ref) do
    case git(path, ["rev-parse", "--verify", ref <> "^{commit}"]) do
      {:ok, sha} when sha != "" -> {:ok, String.downcase(sha)}
      {:ok, _} -> {:error, {:worktree_base_unresolvable, ref, :empty_revision}}
      {:error, detail} -> {:error, {:worktree_base_unresolvable, ref, detail}}
    end
  end

  defp git(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _code} -> {:error, String.trim(out)}
    end
  rescue
    ErlangError -> {:error, :git_unavailable}
  end

  # The phase the worktree is recorded against: the run's latest phase.
  defp phase_id(run, run_id) do
    case Map.get(run, :phase_ids) do
      [_ | _] = ids -> List.last(ids)
      _ -> Identity.phase_id(run_id, 1)
    end
  end
end
