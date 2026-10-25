defmodule ForemanServer.Projects.Adoption do
  @moduledoc """
  Resolves the facts `project.adopt` needs from projections, before the
  command reaches the (pure) `Aggregates.Project`.

  `CommandGateway` calls `resolve/1` as the enrichment step for `project.adopt`
  (the same pattern as `task.approve`/`task.create`), so the aggregate only
  re-validates shapes and the target project's own state.

  A subject is a `task`, a `run` or a `jobsite`. Adopting is a re-home of a
  *thread*: a run moves with its owning task and the task's other runs (the
  thread read model groups them), a task moves with its runs, a jobsite moves
  alone.

  Refusals (each a distinct tuple):

    * `{:project_not_found, id}` - unknown target.
    * `{:subject_not_found, kind, id}` - unknown task/run/jobsite.
    * `{:subject_bound_to_task_provider, "beads"}` - a `beads:<project>:<bead>`
      task belongs to its source project's beads DB (move only).
    * `{:repo_not_in_project, repo_path}` - the subject's repo is neither the
      target project's own path nor one of its attached repositories (E12)
      (move only).

  Archived/paused target and an active subject are decided by the aggregate
  from the enrichment (`subject_active`, `subject_status`).
  """

  alias ForemanServer.ProjectionStore
  alias ForemanServer.Review.Archive

  @type subject_kind :: String.t()

  @doc """
  Enrich a `project.adopt` payload. The payload is the gateway-normalised
  (atom-keyed) payload, extended with `from_project_id`, `subject_active`,
  `subject_status`, `moved`, `repo_path` and `archive_paths`.
  """
  @spec resolve(map()) :: {:ok, map()} | {:error, term()}
  def resolve(payload) when is_map(payload) do
    target_id = fetch(payload, :project_id)
    kind = fetch(payload, :subject_kind)
    subject_id = fetch(payload, :subject_id)
    mode = fetch(payload, :mode) || "move"

    with {:ok, target} <- target(target_id),
         {:ok, subject} <- subject(kind, subject_id) do
      enriched =
        payload
        |> Map.merge(%{
          mode: mode,
          from_project_id: subject.project_id,
          subject_active: subject.active?,
          subject_status: subject.status,
          moved: subject.moved,
          repo_path: subject.repo_path,
          archive_paths: subject.archive_paths
        })

      if mode == "move" and subject.project_id != target_id do
        with :ok <- reject_provider_bound(subject),
             :ok <- check_repo(subject.repo_path, target) do
          {:ok, enriched}
        end
      else
        {:ok, enriched}
      end
    end
  end

  @doc """
  Facts about a subject (no target needed): `project_id`, `active?`, `status`,
  `moved`, `repo_path`, `archive_paths`. `{:error, {:subject_not_found, kind, id}}`
  for an unknown subject.
  """
  @spec facts(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def facts(kind, subject_id), do: subject(kind, subject_id)

  defp target(id) when is_binary(id) and id != "" do
    case ProjectionStore.project(id) do
      %{} = project -> {:ok, project}
      nil -> {:error, {:project_not_found, id}}
    end
  end

  defp target(_), do: {:error, {:missing_or_invalid, :project_id}}

  defp subject("task", id) when is_binary(id) and id != "" do
    case ProjectionStore.task_projection(id) do
      %{} = task ->
        runs = Enum.filter(ProjectionStore.list_runs(), &(&1.task_id == id))
        {:ok, build(:task, task.project_id, [task], runs, [])}

      nil ->
        {:error, {:subject_not_found, "task", id}}
    end
  end

  defp subject("run", id) when is_binary(id) and id != "" do
    case ProjectionStore.run(id) do
      %{} = run ->
        case run.task_id && ProjectionStore.task_projection(run.task_id) do
          %{} = task ->
            runs = Enum.filter(ProjectionStore.list_runs(), &(&1.task_id == task.task_id))
            {:ok, build(:run, run.project_id, [task], runs, [])}

          _no_task ->
            {:ok, build(:run, run.project_id, [], [run], [])}
        end

      nil ->
        {:error, {:subject_not_found, "run", id}}
    end
  end

  defp subject("jobsite", id) when is_binary(id) and id != "" do
    case ProjectionStore.jobsite(id) do
      %{} = jobsite -> {:ok, build(:jobsite, jobsite.project_id, [], [], [jobsite])}
      nil -> {:error, {:subject_not_found, "jobsite", id}}
    end
  end

  # Unknown/missing kind: the aggregate owns the distinct invalid_subject_kind
  # vs missing tuples, so pass a neutral subject through rather than guess.
  defp subject(kind, id) when kind in ["task", "run", "jobsite"],
    do: {:error, {:missing_or_invalid, :subject_id, id}}

  defp subject(_kind, _id), do: {:ok, unknown_subject()}

  defp unknown_subject do
    %{
      project_id: nil,
      active?: false,
      status: nil,
      moved: %{task_ids: [], run_ids: [], jobsite_ids: []},
      repo_path: nil,
      archive_paths: [],
      task_ids: []
    }
  end

  defp build(kind, project_id, tasks, runs, jobsites) do
    active_runs = Enum.filter(runs, &run_active?/1)
    active_jobsites = Enum.filter(jobsites, &jobsite_active?/1)

    # A task with no runs is "active" only on its own in_progress status; with
    # runs the runs decide (a failed run can leave the task status stale).
    active_tasks =
      if runs == [],
        do: Enum.filter(tasks, &(Map.get(&1, :status) == "in_progress")),
        else: []

    status =
      cond do
        active_runs != [] -> hd(active_runs).status
        active_jobsites != [] -> hd(active_jobsites).status
        active_tasks != [] -> "in_progress"
        true -> nil
      end

    repo_path = repo_path(kind, runs, jobsites)

    %{
      project_id: project_id,
      active?: not is_nil(status),
      status: status,
      moved: %{
        task_ids: Enum.map(tasks, & &1.task_id),
        run_ids: Enum.map(runs, & &1.run_id),
        jobsite_ids: Enum.map(jobsites, & &1.jobsite_id)
      },
      repo_path: repo_path,
      archive_paths: archive_paths(repo_path, runs, jobsites),
      task_ids: Enum.map(tasks, & &1.task_id)
    }
  end

  # A paused run still holds its project's run reservation, so it counts as
  # active: re-homing it would strand the reservation on the source project.
  defp run_active?(run), do: not Map.get(run, :terminal?, false)
  defp jobsite_active?(js), do: not Map.get(js, :terminal?, false)

  defp repo_path(_kind, _runs, [%{repo_path: path} | _]) when is_binary(path), do: path

  defp repo_path(_kind, runs, _jobsites) do
    runs
    |> Enum.flat_map(&ProjectionStore.worktrees_for_run(&1.run_id))
    |> Enum.find_value(fn wt -> is_binary(wt.repo_path) && wt.repo_path end)
  end

  defp archive_paths(nil, _runs, _jobsites), do: []

  defp archive_paths(repo_path, runs, jobsites) do
    Enum.map(runs, &Archive.dir(:run, &1.run_id, repo_path)) ++
      Enum.map(jobsites, &Archive.dir(:jobsite, &1.jobsite_id, repo_path))
  end

  defp reject_provider_bound(%{task_ids: ids}) do
    if Enum.any?(ids, &String.starts_with?(&1, "beads:")),
      do: {:error, {:subject_bound_to_task_provider, "beads"}},
      else: :ok
  end

  # The subject's repo must be one of the target's repositories: its own path or an
  # attached one (E12). A subject with no discoverable repo (a task that never ran)
  # has nothing to mismatch.
  defp check_repo(nil, _target), do: :ok

  defp check_repo(repo_path, %{project_id: target_id}) do
    repos = ProjectionStore.project_repositories(target_id) || []

    if Enum.any?(repos, &same_path?(repo_path, &1.path)),
      do: :ok,
      else: {:error, {:repo_not_in_project, repo_path}}
  end

  defp same_path?(a, b) when is_binary(a) and is_binary(b), do: Path.expand(a) == Path.expand(b)
  defp same_path?(_a, _b), do: false

  defp fetch(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
