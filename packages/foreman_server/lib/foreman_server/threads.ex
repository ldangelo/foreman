defmodule ForemanServer.Threads do
  @moduledoc """
  Read facade over the thread read model (see `ForemanServer.Threads.Thread`).

  Both doors are served from one bulk `ProjectionStore.thread_inputs/0` call,
  so listing never makes a GenServer call per row. `get/1` resolves through the
  same builder as `list/2`, so the two can never disagree about a thread.
  """

  alias ForemanServer.ProjectionStore
  alias ForemanServer.Threads.Thread

  @default_limit 100
  @max_limit 500

  @type opts :: [
          status: String.t(),
          door: Thread.door(),
          resolved: boolean(),
          limit: pos_integer()
        ]

  @doc "Maximum accepted `:limit`."
  @spec max_limit() :: pos_integer()
  def max_limit, do: @max_limit

  @doc """
  Threads of a project, most recently updated first.

  Options: `:status` (raw status), `:door` (`:workflow | :jobsite`), `:resolved`
  (`true | false`, omitted = both), `:limit`
  (default #{@default_limit}, clamped to 1..#{@max_limit}).
  """
  @spec list(String.t(), opts()) :: [Thread.t()]
  def list(project_id, opts \\ []) when is_binary(project_id) and is_list(opts) do
    status = Keyword.get(opts, :status)
    door = Keyword.get(opts, :door)
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()
    resolved = Keyword.get(opts, :resolved)

    ProjectionStore.thread_inputs()
    |> build_all()
    |> Enum.filter(fn thread ->
      thread.project_id == project_id and
        (is_nil(status) or thread.status == status) and
        (is_nil(door) or thread.door == door) and
        (is_nil(resolved) or thread.resolved == resolved)
    end)
    |> Enum.take(limit)
  end

  @doc "One thread by id (`run:<id>` or `jobsite:<id>`)."
  @spec get(String.t()) :: {:ok, Thread.t()} | {:error, :thread_not_found}
  def get(thread_id) when is_binary(thread_id) do
    case Enum.find(build_all(ProjectionStore.thread_inputs()), &(&1.id == thread_id)) do
      %Thread{} = thread -> {:ok, thread}
      nil -> {:error, :thread_not_found}
    end
  end

  @doc """
  Every thread, grouped by project id, each list most recently updated first.

  One bulk projection read and one thread build for all projects, so a caller
  that needs several projects (the project list's attention flags) pays for the
  build once instead of once per project. Unlike `list/2` it applies no limit.
  """
  @spec by_project() :: %{String.t() => [Thread.t()]}
  def by_project do
    ProjectionStore.thread_inputs()
    |> build_all()
    |> Enum.group_by(& &1.project_id)
  end

  @doc """
  The thread that owns each of the given run ids, as `%{run_id => thread}`; run
  ids no thread owns are absent. Unlike `list/2` there is no limit: a thread
  outside the newest-`max_limit/0` window is still found.
  """
  @spec by_run_ids([String.t()]) :: %{String.t() => Thread.t()}
  def by_run_ids(run_ids) when is_list(run_ids) do
    wanted = MapSet.new(run_ids)

    for %Thread{run_ids: owned} = thread <- build_all(ProjectionStore.thread_inputs()),
        run_id <- owned,
        MapSet.member?(wanted, run_id),
        into: %{},
        do: {run_id, thread}
  end

  defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_limit)

  defp build_all(inputs) do
    %{
      runs: runs,
      tasks: tasks,
      jobsites: jobsites,
      worktrees: worktrees,
      pr_associations: pr_associations,
      reviews: reviews
    } = inputs

    thread_flags = Map.get(inputs, :thread_flags, %{})

    # A task entry without `:task_id` is a fragment a lifecycle event (e.g.
    # `TaskExecutionCompleted`) left for a task whose `TaskCreated` was never
    # projected. It is not a task, so no thread is built from it.
    tasks = Enum.filter(tasks, &is_map_key(&1, :task_id))

    tasks_by_id = Map.new(tasks, &{&1.task_id, &1})

    tasks_by_external_id =
      for %{external_id: id} = t <- tasks, is_binary(id), into: %{}, do: {id, t}

    # Newest run first; one thread per task, task-less runs stand alone.
    sorted_runs = Enum.sort_by(runs, &{&1.last_event_at_ms, &1.run_id}, :desc)

    groups =
      sorted_runs
      |> Enum.group_by(fn run -> run.task_id || {:run, run.run_id} end)
      |> Map.values()

    worktrees_by_run = Enum.group_by(worktrees, & &1.run_id)

    run_threads =
      Enum.map(groups, fn [run | _] = group ->
        Thread.from_run(
          run,
          run.task_id && Map.get(tasks_by_id, run.task_id),
          Map.get(worktrees_by_run, run.run_id, []),
          pr_association(pr_associations, run.run_id),
          Map.get(reviews, {"run", run.run_id}),
          Enum.map(group, & &1.run_id)
        )
      end)

    # A bead-linked jobsite whose task already has a run is that run's thread.
    owned_beads =
      for run <- runs,
          task = run.task_id && Map.get(tasks_by_id, run.task_id),
          is_binary(task.external_id),
          into: MapSet.new(),
          do: task.external_id

    jobsite_threads =
      for jobsite <- jobsites,
          bead_id <- [Map.get(jobsite, :bead_id)],
          not MapSet.member?(owned_beads, bead_id) do
        Thread.from_jobsite(
          jobsite,
          bead_id && Map.get(tasks_by_external_id, bead_id),
          Map.get(reviews, {"jobsite", jobsite.jobsite_id})
        )
      end

    (run_threads ++ jobsite_threads)
    |> Enum.map(&apply_flags(&1, thread_flags))
    |> Enum.sort_by(&{&1.updated_at || 0, &1.id}, :desc)
  end

  defp apply_flags(%Thread{id: id} = thread, thread_flags) do
    case Map.get(thread_flags, id) do
      %{resolved: true} -> %Thread{thread | resolved: true}
      _ -> thread
    end
  end

  defp pr_association(pr_associations, run_id) do
    case Map.fetch(pr_associations, run_id) do
      {:ok, assoc} -> {:ok, assoc}
      :error -> {:error, :not_found}
    end
  end
end
