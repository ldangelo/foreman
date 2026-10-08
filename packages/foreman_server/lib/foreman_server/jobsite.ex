defmodule ForemanServer.Jobsite do
  @moduledoc """
  Public API for scripted, event-sourced agent runs ("jobsites").

  `run/1` and `run_async/1` require the application to be running (plain
  `mix run`, not `--no-start`): both dispatch through
  `CommandGateway.dispatch_system/2`, which needs `CommandRouter` +
  `EventStore` + Postgres.
  """

  alias ForemanServer.Jobsite.{Control, Error, Git, Result, Sandbox, Supervisor, Worktree}
  alias ForemanServer.ProjectionStore

  @doc """
  Run a jobsite to completion and block until it finishes. Generates the
  jobsite id, starts its `Executor` with `reply_to: self()`, and waits for
  the `{:jobsite, id, outcome}` reply.
  """
  @spec run(keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
  def run(opts) do
    id = generate_id()
    start_and_await(id, Keyword.put(opts, :reply_to, self()))
  end

  @doc "Start a jobsite in the background and return its id immediately."
  @spec run_async(keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def run_async(opts) do
    id = generate_id()

    case Supervisor.start_jobsite(id, opts) do
      {:ok, _pid} -> {:ok, id}
      {:error, reason} -> {:error, start_failed_error(reason)}
    end
  end

  @doc """
  Create a worktree and attach a sandbox to it in one call. The returned
  sandbox owns the worktree: `Sandbox.close/1` also closes it.
  """
  @spec create_sandbox(keyword()) :: {:ok, Sandbox.t()} | {:error, Error.t()}
  def create_sandbox(opts) do
    with {:ok, worktree} <- Worktree.create(opts),
         {:ok, sandbox} <- Worktree.create_sandbox(worktree, opts) do
      {:ok, %{sandbox | owns_worktree?: true}}
    end
  end

  @doc "Create a worktree without a sandbox."
  @spec create_worktree(keyword()) :: {:ok, Worktree.t()} | {:error, Error.t()}
  def create_worktree(opts), do: Worktree.create(opts)

  @doc """
  Resume a paused or crashed jobsite. Rehydrates authoritative state from the
  event stream (`ForemanServer.Aggregate.load/2`), not from the projection
  and not from process memory, so it works even after a hard kill.
  """
  @spec resume(String.t()) :: {:ok, Result.t()} | {:error, Error.t()}
  def resume(jobsite_id) do
    start_and_await(jobsite_id, reply_to: self(), resume?: true)
  end

  @doc """
  Resume a paused or crashed jobsite in the background and return immediately.

  The Executor reports a rejected resume only to `reply_to`, and a background
  resume has none, so the preconditions are checked here against the same
  authoritative event-stream state the Executor loads: an unknown id is
  `:jobsite_not_found`, a terminal one `:not_resumable`, one whose Executor is
  alive `:already_running`.
  """
  @spec resume_async(String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def resume_async(jobsite_id) do
    {state, _version} =
      ForemanServer.Aggregate.load(ForemanServer.Aggregates.Jobsite, "jobsite:" <> jobsite_id)

    cond do
      not state.exists? ->
        {:error,
         Error.new(:jobsite_not_found, "jobsite #{jobsite_id} does not exist", %{
           jobsite_id: jobsite_id
         })}

      state.terminal? ->
        {:error,
         Error.new(:not_resumable, "jobsite #{jobsite_id} is already #{state.status}", %{
           jobsite_id: jobsite_id,
           status: state.status
         })}

      ForemanServer.Jobsite.Executor.pid_for(jobsite_id) != nil ->
        {:error,
         Error.new(:already_running, "jobsite #{jobsite_id} is already running", %{
           jobsite_id: jobsite_id
         })}

      true ->
        case Supervisor.resume_jobsite(jobsite_id, []) do
          {:ok, _pid} -> {:ok, jobsite_id}
          {:error, reason} -> {:error, start_failed_error(reason)}
        end
    end
  end

  @doc """
  Pause a running jobsite: the executor commits whatever is in the worktree,
  releases the sandbox, keeps the worktree, and exits. Not terminal — the
  jobsite can be continued via `resume/1`.
  """
  @spec pause(String.t(), String.t()) :: :ok | {:error, Error.t()}
  def pause(jobsite_id, reason) when is_binary(reason) and reason != "" do
    Control.request(jobsite_id, {:pause, reason})
  end

  @doc "Cancel a running jobsite: the executor discards its work and exits."
  @spec cancel(String.t(), String.t()) :: :ok | {:error, Error.t()}
  def cancel(jobsite_id, reason) when is_binary(reason) and reason != "" do
    Control.request(jobsite_id, {:cancel, reason})
  end

  @doc "Return the projected state for a jobsite, or nil if not found."
  @spec get(String.t()) :: map() | nil
  def get(jobsite_id), do: ProjectionStore.jobsite(jobsite_id)

  @doc "Return every projected jobsite, newest-started-first."
  @spec list() :: [map()]
  def list, do: ProjectionStore.list_jobsites()

  @doc """
  Merge a named branch (e.g. one produced by a separate jobsite's
  `{:branch, name}` strategy) into the repo's current branch. A conflict
  aborts the merge and reports, leaving the source branch intact for manual
  resolution.
  """
  @spec merge_branch(String.t(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def merge_branch(branch, opts \\ []) do
    repo_path = Keyword.get(opts, :repo_path, File.cwd!())

    case Git.merge(repo_path, branch) do
      {:ok, output} ->
        with :ok <- Git.delete_branch(repo_path, branch) do
          {:ok, output}
        end

      {:error, {:merge_conflict, output}} ->
        Git.merge_abort(repo_path)

        {:error,
         Error.new(:merge_conflict, "merge produced conflicts", %{branch: branch, output: output})}
    end
  end

  @doc """
  Merge a COMPLETED jobsite's branch into the branch `into`, which must be the
  one currently checked out in the jobsite's repository.

  This mutates the repository's working checkout, so it is deliberately narrow:
  the caller names the target branch and the call refuses unless that is the
  checked-out one (it never merges "into whatever HEAD happens to be"), the
  jobsite must have completed, and its branch must still exist. State is read
  from the event stream, not the projection, which carries no `repo_path`.
  """
  @spec merge_into(String.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def merge_into(jobsite_id, into) when is_binary(into) and into != "" do
    {state, _version} =
      ForemanServer.Aggregate.load(ForemanServer.Aggregates.Jobsite, "jobsite:" <> jobsite_id)

    cond do
      not state.exists? ->
        {:error,
         Error.new(:jobsite_not_found, "jobsite #{jobsite_id} does not exist", %{
           jobsite_id: jobsite_id
         })}

      state.status != "completed" or not is_binary(state.branch) ->
        {:error,
         Error.new(:not_completed, "only a completed jobsite with a branch can be merged", %{
           jobsite_id: jobsite_id,
           status: state.status
         })}

      not Git.branch_exists?(state.repo_path, state.branch) ->
        {:error,
         Error.new(
           :branch_missing,
           "branch #{state.branch} no longer exists (already merged?)",
           %{
             branch: state.branch
           }
         )}

      true ->
        with {:ok, current} <- Git.current_branch(state.repo_path),
             :ok <- require_checked_out(current, into),
             {:ok, _output} <- merge_branch(state.branch, repo_path: state.repo_path) do
          {:ok, %{jobsite_id: jobsite_id, branch: state.branch, merged_into: into}}
        end
    end
  end

  defp require_checked_out(current, current), do: :ok

  defp require_checked_out(current, into) do
    {:error,
     Error.new(:merge_target_mismatch, "#{into} is not the checked-out branch (#{current})", %{
       requested: into,
       checked_out: current
     })}
  end

  defp start_and_await(jobsite_id, opts) do
    start_fun =
      if Keyword.get(opts, :resume?, false),
        do: &Supervisor.resume_jobsite/2,
        else: &Supervisor.start_jobsite/2

    case start_fun.(jobsite_id, opts) do
      {:ok, _pid} ->
        receive do
          {:jobsite, ^jobsite_id, outcome} -> outcome
        end

      {:error, reason} ->
        {:error, start_failed_error(reason)}
    end
  end

  defp start_failed_error(reason) do
    Error.new(:dispatch_rejected, "failed to start jobsite executor", %{reason: reason})
  end

  defp generate_id do
    "js-" <> (16 |> div(2) |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower))
  end
end
