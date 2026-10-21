defmodule ForemanServer.Threads.Thread do
  @moduledoc """
  The operator-facing unit of work: one session with its own branch/PR.

  A thread is a read-model value composed from projections that already exist
  (task, run, worktree, PR association, review, jobsite). No event backs it.

    * workflow door - id `"run:<run_id>"`: the newest run of a task (or of a
      task-less run). `run_ids` lists every run of that task, newest first.
    * jobsite door - id `"jobsite:<jobsite_id>"`: a jobsite that no task-owned
      run already represents.

  `steering` is a constant: S2 decided that v1 steering is pause, then resume
  with the operator message injected into the next prompt. Live mid-turn
  steering is not built, so every thread reports `"pause_resume"`.

  `resolved` is the operator disposition flag; it is always `false` here and
  is filled by the thread resolve/reopen story.

  The builders are pure: they take already-fetched projection maps and never
  call `ProjectionStore`.
  """

  @enforce_keys [:id, :door, :project_id, :title, :status]
  @type door :: :workflow | :jobsite
  @type last_report :: %{verdict: String.t(), summary: String.t() | nil, at: String.t() | nil}
  @type t :: %__MODULE__{
          id: String.t(),
          door: door(),
          project_id: String.t() | nil,
          task_id: String.t() | nil,
          title: String.t(),
          status: String.t() | nil,
          branch: String.t() | nil,
          repo_path: String.t() | nil,
          pr_url: String.t() | nil,
          last_report: last_report() | nil,
          provider_session_id: String.t() | nil,
          resolved: boolean(),
          steering: String.t(),
          run_ids: [String.t()],
          created_at: integer() | nil,
          updated_at: integer() | nil
        }
  defstruct [
    :id,
    :door,
    :project_id,
    :task_id,
    :title,
    :status,
    :branch,
    :repo_path,
    :pr_url,
    :last_report,
    :provider_session_id,
    :created_at,
    :updated_at,
    resolved: false,
    steering: "pause_resume",
    run_ids: []
  ]

  @dto_keys ~w(id door project_id task_id title status branch repo_path pr_url last_report
               provider_session_id resolved steering run_ids created_at updated_at)

  @doc """
  Build a workflow-door thread from a run projection, its task (or nil), the
  run's worktrees, its PR association (`{:ok, map}` | `{:error, :not_found}`),
  its review (or nil) and the ids of every run of the task, newest first.

  `provider_session_id` is the run projection's `:provider_session_id` (bound
  by `WorkerSessionBound`).
  """
  @spec from_run(
          map(),
          map() | nil,
          [map()],
          {:ok, map()} | {:error, :not_found},
          map() | nil,
          [String.t()]
        ) :: t()
  def from_run(run, task, worktrees, pr_assoc, review, run_ids)
      when is_map(run) and is_list(worktrees) and is_list(run_ids) do
    run_id = fetch(run, :run_id)
    worktree = worktrees |> Enum.reverse() |> Enum.find(&(fetch(&1, :branch) != nil))

    %__MODULE__{
      id: "run:" <> run_id,
      door: :workflow,
      project_id: fetch(run, :project_id),
      task_id: fetch(run, :task_id),
      title: title(task, run_id),
      status: fetch(run, :status),
      branch: worktree && fetch(worktree, :branch),
      repo_path: worktree && fetch(worktree, :repo_path),
      pr_url: fetch(run, :pr_url) || pr_url(pr_assoc),
      last_report: last_report(review),
      provider_session_id: fetch(run, :provider_session_id),
      run_ids: run_ids,
      created_at: fetch(run, :started_at_ms),
      updated_at: fetch(run, :last_event_at_ms)
    }
  end

  @doc """
  Build a jobsite-door thread from a jobsite projection, the task that owns
  its bead (or nil) and its review (or nil). `provider_session_id` is the
  jobsite projection's `:session_id`.
  """
  @spec from_jobsite(map(), map() | nil, map() | nil) :: t()
  def from_jobsite(jobsite, task, review) when is_map(jobsite) do
    jobsite_id = fetch(jobsite, :jobsite_id)

    %__MODULE__{
      id: "jobsite:" <> jobsite_id,
      door: :jobsite,
      project_id: fetch(jobsite, :project_id),
      task_id: task && fetch(task, :task_id),
      title: title(task, jobsite_id),
      status: fetch(jobsite, :status),
      branch: fetch(jobsite, :branch),
      repo_path: fetch(jobsite, :repo_path),
      pr_url: nil,
      last_report: last_report(review),
      provider_session_id: fetch(jobsite, :session_id),
      created_at: fetch(jobsite, :started_at_ms),
      updated_at: fetch(jobsite, :updated_at_ms)
    }
  end

  @doc "Whitelisted string-keyed JSON shape shared by HTTP and MCP."
  @spec to_dto(t()) :: %{String.t() => term()}
  def to_dto(%__MODULE__{} = thread) do
    last_report =
      case thread.last_report do
        nil ->
          nil

        report ->
          %{
            "verdict" => report.verdict,
            "summary" => report.summary,
            "at" => report.at
          }
      end

    thread
    |> Map.from_struct()
    |> Map.put(:door, Atom.to_string(thread.door))
    |> Map.put(:last_report, last_report)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.take(@dto_keys)
  end

  defp title(task, fallback_id) do
    case task do
      nil ->
        fallback_id

      task ->
        non_blank(fetch(task, :title)) ||
          first_line(fetch(task, :prompt)) ||
          first_line(fetch(task, :description)) ||
          fetch(task, :task_id) || fallback_id
    end
  end

  defp first_line(text) when is_binary(text) do
    text |> String.split(["\r\n", "\n"]) |> Enum.find_value(&non_blank/1)
  end

  defp first_line(_), do: nil

  defp non_blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp non_blank(_), do: nil

  defp pr_url({:ok, assoc}) when is_map(assoc), do: fetch(assoc, :pr_url)
  defp pr_url(_), do: nil

  defp last_report(nil), do: nil

  defp last_report(review) when is_map(review) do
    case fetch(review, :verdict) do
      verdict when is_binary(verdict) ->
        %{verdict: verdict, summary: fetch(review, :summary), at: fetch(review, :at)}

      _ ->
        nil
    end
  end

  defp fetch(map, key), do: Map.get(map, key)
end
