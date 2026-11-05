defmodule ForemanServerWeb.Workspace.NavRuns do
  @moduledoc """
  The typed read model behind the workspace nav's Workflows and Jobsites panels.

  `build_runs/4` and `build_jobsites/2` are pure: they take already-read projection values and
  return `Run` / `Jobsite` structs whose absent values are explicit sentinels (`:none`,
  `:absent`), never `nil`. `read/1` does the bulk reads (five `ProjectionStore` calls, once each,
  none per run) and delegates.

  Worktree state is the projection's claim: `"cleaned"` is `:removed`, `"created"` with
  `cleanup == "never"` is `:kept`, any other `"created"` is `:active`. A status the projection
  does not define raises, so a new one is a visible defect.
  """

  alias ForemanServer.ProjectionStore
  alias ForemanServer.Threads.Thread
  alias ForemanServerWeb.OperatorDashboard
  alias ForemanServerWeb.OperatorDashboard.RunDTO
  alias ForemanServerWeb.Workspace.Components

  defmodule Run do
    @moduledoc false
    @enforce_keys [
      :run_id,
      :status,
      :workflow,
      :title,
      :started_at_ms,
      :branch,
      :worktree,
      :pr,
      :trd_path,
      :thread_id
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            run_id: String.t(),
            status: String.t(),
            workflow: String.t() | :absent,
            title: String.t(),
            started_at_ms: integer() | :absent,
            branch: %{name: String.t(), base: String.t() | :none} | :none,
            worktree:
              %{
                path: String.t() | :none,
                state: :kept | :active | :removed,
                cleanup: String.t() | :none
              }
              | :none,
            pr: %{url: String.t(), state: atom() | :none} | :none,
            trd_path: String.t() | :none,
            thread_id: String.t()
          }
  end

  defmodule Jobsite do
    @moduledoc false
    @enforce_keys [
      :jobsite_id,
      :status,
      :bead_id,
      :title,
      :branch,
      :worktree_path,
      :thread_id
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            jobsite_id: String.t(),
            status: String.t(),
            bead_id: String.t() | :none,
            title: String.t(),
            branch: String.t() | :none,
            worktree_path: String.t() | :none,
            thread_id: String.t()
          }
  end

  @doc """
  The project's runs (newest-first as `OperatorDashboard.list_runs/1` orders them) and jobsites
  for the nav. Five `ProjectionStore` reads, once each, however many runs: `list_runs`
  (`detail: :summary`), `list_jobsites/0`, `list_tasks/0`, `worktrees_for_runs/1` and
  `pr_states_for_project/1`. The one task list titles runs (by `task_id`) and jobsites (by the
  task whose `external_id` is their bead).
  """
  @spec read(String.t()) :: %{runs: [Run.t()], jobsites: [Jobsite.t()]}
  def read(project_id) when is_binary(project_id) and project_id != "" do
    # Only the documented success shape is matched: the filter is built here, so an error is
    # a defect, and an empty panel would hide it.
    {:ok, dtos} = OperatorDashboard.list_runs(%{project_id: project_id, detail: :summary})

    jobsites =
      Enum.filter(ProjectionStore.list_jobsites(), &(Map.get(&1, :project_id) == project_id))

    tasks = Enum.filter(ProjectionStore.list_tasks(), &is_map_key(&1, :task_id))
    tasks_by_id = Map.new(tasks, &{&1.task_id, &1})

    # A bead id is only unique within its project: the same one in another project's task must
    # not title this project's jobsite.
    tasks_by_external_id =
      for %{external_id: external_id, project_id: ^project_id} = task <- tasks,
          is_binary(external_id),
          into: %{} do
        {external_id, task}
      end

    worktrees_by_run = dtos |> Enum.map(& &1.run_id) |> ProjectionStore.worktrees_for_runs()
    pr_states = ProjectionStore.pr_states_for_project(project_id)

    %{
      runs: build_runs(dtos, tasks_by_id, worktrees_by_run, pr_states),
      jobsites: build_jobsites(jobsites, tasks_by_external_id)
    }
  end

  @spec build_runs([RunDTO.t()], map(), map(), map()) :: [Run.t()]
  def build_runs(run_dtos, tasks_by_id, worktrees_by_run, pr_states)
      when is_list(run_dtos) and is_map(tasks_by_id) and is_map(worktrees_by_run) and
             is_map(pr_states) do
    Enum.map(run_dtos, &build_run(&1, tasks_by_id, worktrees_by_run, pr_states))
  end

  defp build_run(%RunDTO{run_id: run_id, status: status} = dto, tasks, worktrees, pr_states) do
    unless is_binary(run_id) and run_id != "",
      do: raise(ArgumentError, "nav run has no run_id: #{inspect(dto)}")

    unless is_binary(status) and status != "",
      do: raise(ArgumentError, "nav run #{run_id} has no status")

    task = if is_binary(dto.task_id), do: Map.get(tasks, dto.task_id)
    records = Map.get(worktrees, run_id, [])

    %Run{
      run_id: run_id,
      status: status,
      workflow: dto.workflow,
      title: Thread.title(task, run_id),
      started_at_ms: dto.started_at_ms,
      branch: branch(records),
      worktree: worktree(records),
      pr: pr(dto, Map.get(pr_states, run_id)),
      trd_path: if(task, do: text(task, :trd_path), else: :none),
      thread_id: "run:" <> run_id
    }
  end

  # The last record, in operation_id order, that has a branch: the same pick as
  # `Threads.Thread.from_run/6`. Branch and worktree both come from it, so a multi-repo run
  # never shows one repository's branch beside another's checkout.
  defp branch(records) do
    case branch_record(records) do
      nil -> :none
      record -> %{name: record.branch, base: text(record, :base_ref)}
    end
  end

  defp branch_record(records),
    do: records |> Enum.reverse() |> Enum.find(&(Map.get(&1, :branch) != nil))

  # The same record as the branch; a run whose records carry no branch falls back to its
  # newest record, so its checkout is still shown.
  defp worktree([]), do: :none

  defp worktree(records) do
    record = branch_record(records) || List.last(records)

    %{
      path: text(record, :worktree_path),
      state: worktree_state(record),
      cleanup: text(record, :cleanup)
    }
  end

  defp worktree_state(%{status: "cleaned"}), do: :removed
  defp worktree_state(%{status: "created", cleanup: "never"}), do: :kept
  defp worktree_state(%{status: "created"}), do: :active

  defp worktree_state(record) do
    raise ArgumentError,
          "unknown worktree status #{inspect(Map.get(record, :status))} " <>
            "(operation #{inspect(Map.get(record, :operation_id))})"
  end

  defp pr(dto, pr_state) do
    url =
      Components.safe_url(
        present(dto.pr_url) || (pr_state && present(Map.get(pr_state, :pr_url)))
      )

    case url do
      nil -> :none
      url -> %{url: url, state: pr_state_name(pr_state)}
    end
  end

  @spec build_jobsites([map()], map()) :: [Jobsite.t()]
  def build_jobsites(jobsites, tasks_by_external_id)
      when is_list(jobsites) and is_map(tasks_by_external_id) do
    Enum.map(jobsites, &build_jobsite(&1, tasks_by_external_id))
  end

  defp build_jobsite(jobsite, tasks) do
    jobsite_id = Map.fetch!(jobsite, :jobsite_id)
    status = Map.fetch!(jobsite, :status)
    bead_id = present(Map.get(jobsite, :bead_id))
    task = bead_id && Map.get(tasks, bead_id)

    %Jobsite{
      jobsite_id: jobsite_id,
      status: status,
      bead_id: bead_id || :none,
      title: Thread.title(task, bead_id || jobsite_id),
      branch: text(jobsite, :branch),
      worktree_path: text(jobsite, :worktree_path),
      thread_id: "jobsite:" <> jobsite_id
    }
  end

  defp pr_state_name(%{pr_state: state}) when is_atom(state) and state != nil, do: state
  defp pr_state_name(_), do: :none

  # A projected string field, `:none` when nil or blank.
  defp text(map, key) do
    case present(Map.get(map, key)) do
      nil -> :none
      value -> value
    end
  end

  defp present(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp present(_), do: nil
end
