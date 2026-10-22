defmodule ForemanServer.Workflow.RepoPrContext do
  @moduledoc """
  Everything needed to open one repository's PR for a run, built from the
  projections alone (never from executor state), so the same context serves
  finalisation and a later `run.pr.retry`.

  `build/2` joins the run projection (project, task, base branch) with the
  repository's run worktree (`ProjectionStore.run_repositories/1`): the PR head
  is the worktree branch, the AutoPR working directory is that repository's
  project root (`git push origin <branch>` runs from the repo root, as for a
  single-repository run), and the base branch is the one recorded for that
  repository when the run started.
  """

  alias ForemanServer.ProjectionStore

  @enforce_keys [:run_id, :repo_id, :primary?, :project_id, :task_id, :auto_pr]
  defstruct [:run_id, :repo_id, :primary?, :project_id, :task_id, :auto_pr]

  @type t :: %__MODULE__{
          run_id: String.t(),
          repo_id: String.t(),
          primary?: boolean(),
          project_id: String.t() | nil,
          task_id: String.t() | nil,
          auto_pr: map()
        }

  @type error ::
          :run_not_found
          | {:unknown_repo, String.t()}
          | {:no_worktree, String.t()}
          | {:base_branch_unrecorded, String.t()}

  @doc """
  Builds the context for `repo_id` (the effective string id) of `run_id`.
  `:auto_pr` is the map `ForemanServer.Workflow.AutoPR.maybe_create_pr/1` takes.
  """
  @spec build(String.t(), String.t()) :: {:ok, t()} | {:error, error()}
  def build(run_id, repo_id) when is_binary(run_id) and is_binary(repo_id) do
    with %{} = run <- ProjectionStore.run(run_id) || {:error, :run_not_found},
         {:ok, entry} <- fetch_entry(run_id, repo_id),
         {:ok, worktree} <- fetch_worktree(entry, repo_id),
         {:ok, base_branch} <- fetch_base_branch(entry, repo_id) do
      auto_pr =
        %{
          run_id: run_id,
          base_branch: base_branch,
          head_branch: worktree.branch,
          cwd: worktree.repo_path
        }
        |> put_task_metadata(run_id, Map.get(run, :task_id))

      {:ok,
       %__MODULE__{
         run_id: run_id,
         repo_id: repo_id,
         primary?: entry.primary?,
         project_id: Map.get(run, :project_id),
         task_id: Map.get(run, :task_id),
         auto_pr: auto_pr
       }}
    end
  end

  defp fetch_entry(run_id, repo_id) do
    case Enum.find(ProjectionStore.run_repositories(run_id), &(&1.repo_id == repo_id)) do
      nil -> {:error, {:unknown_repo, repo_id}}
      entry -> {:ok, entry}
    end
  end

  defp fetch_worktree(%{worktree: %{branch: branch, repo_path: path} = worktree}, _repo_id)
       when is_binary(branch) and branch != "" and is_binary(path) and path != "",
       do: {:ok, worktree}

  defp fetch_worktree(_entry, repo_id), do: {:error, {:no_worktree, repo_id}}

  defp fetch_base_branch(%{base_branch: branch}, _repo_id)
       when is_binary(branch) and branch != "",
       do: {:ok, branch}

  defp fetch_base_branch(_entry, repo_id), do: {:error, {:base_branch_unrecorded, repo_id}}

  # The task's title/description, only when the run's task is projected with
  # both a title and a description. A nil field is omitted rather than stored
  # as nil (AutoPR distinguishes absent from malformed; AGENTS.md 5.3).
  defp put_task_metadata(context, run_id, task_id) do
    task =
      case ProjectionStore.tasks_by_run_id(run_id) do
        [task | _] -> task
        [] when is_binary(task_id) and task_id != "" -> ProjectionStore.task_projection(task_id)
        [] -> nil
      end

    case task do
      %{title: title} when is_binary(title) ->
        context
        |> Map.put(:task_title, title)
        |> then(fn ctx ->
          case Map.get(task, :description) do
            nil -> ctx
            description -> Map.put(ctx, :task_description, description)
          end
        end)

      _ ->
        context
    end
  end
end
