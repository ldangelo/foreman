defmodule ForemanServer.Jobsite do
  @moduledoc """
  Public API for scripted, event-sourced agent runs ("jobsites").

  `run/1` and `run_async/1` require the application to be running (plain
  `mix run`, not `--no-start`): both dispatch through
  `CommandGateway.dispatch_system/2`, which needs `CommandRouter` +
  `EventStore` + Postgres.
  """

  require Logger

  alias ForemanServer.Jobsite.{
    Control,
    Error,
    Executor,
    Git,
    Result,
    Sandbox,
    Supervisor,
    Worktree
  }

  alias ForemanServer.ProjectionStore

  @doc """
  Run a jobsite to completion and block until it finishes. Generates the
  jobsite id, starts its `Executor` with `reply_to: self()`, and waits for
  the `{:jobsite, id, outcome}` reply.
  """
  @spec run(keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
  def run(opts) do
    id = generate_id()

    with :ok <- Executor.reserve_thread(id, opts) do
      start_and_await(id, Keyword.put(opts, :reply_to, self()))
    end
  end

  @doc """
  Start a jobsite in the background and return its id.

  The id is readable (`get/1`, `GET /api/jobsites/:id`) when this returns: the call holds until
  the Executor has recorded `jobsite.start` (or, for a spec it refuses, the stub start that its
  typed failure hangs on), which is after `build_spec`, so a slow project setup delays the
  return by that long, bounded by `@started_timeout_ms`. If the Executor ends without ever
  recording a start (a rejected start dispatch, a crash in `build_spec`) the id would 404
  forever, so that is `{:error, :jobsite_start_failed}`. If only the bound passes the Executor is
  still working: the id is returned (and a warning logged) because it becomes readable once
  the start lands.
  """
  @spec run_async(keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def run_async(opts) do
    id = generate_id()
    ref = make_ref()

    with :ok <- Executor.reserve_thread(id, opts) do
      case Supervisor.start_jobsite(id, Keyword.put(opts, :started_notify, {self(), ref})) do
        {:ok, pid} ->
          case await_started(id, pid, ref) do
            :ok -> {:ok, id}
            {:error, reason} -> {:error, executor_died_error(reason)}
          end

        {:error, reason} ->
          {:error, start_failed_error(reason)}
      end
    end
  end

  @started_timeout_ms 30_000

  defp await_started(id, pid, ref) do
    monitor = Process.monitor(pid)

    receive do
      {^ref, :jobsite_started} ->
        Process.demonitor(monitor, [:flush])
        :ok

      # The Executor sends `:jobsite_started` before it can exit, so a `:DOWN` first means it
      # ended with no `jobsite.start` recorded.
      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:executor_exited_before_start, reason}}
    after
      @started_timeout_ms ->
        Process.demonitor(monitor, [:flush])

        receive do
          {^ref, :jobsite_started} ->
            :ok
        after
          0 ->
            Logger.warning(
              "Jobsite #{id} not yet started after #{@started_timeout_ms}ms; returning its id anyway"
            )

            :ok
        end
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
    with {:ok, _state} <- ForemanServer.Jobsite.Executor.check_resumable(jobsite_id),
         :ok <- require_not_running(jobsite_id) do
      start_and_await(jobsite_id, reply_to: self(), resume?: true)
    end
  end

  @doc """
  Resume a paused or crashed jobsite in the background and return immediately.

  The Executor reports a rejected resume only to `reply_to`, and a background
  resume has none, so the preconditions are checked here, via the same
  `Executor.check_resumable/1` the Executor itself uses: an unknown id is
  `:jobsite_not_found`, a terminal one or one that never provisioned a worktree
  `:not_resumable`, one whose agent never reported a provider session
  `:no_session`, one whose Executor is alive `:already_running`.
  """
  @spec resume_async(String.t(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def resume_async(jobsite_id, opts \\ []) do
    with :ok <- validate_resume_prompt(Keyword.get(opts, :prompt)),
         {:ok, _state} <- ForemanServer.Jobsite.Executor.check_resumable(jobsite_id),
         :ok <- require_not_running(jobsite_id),
         {:ok, _pid} <- resume_child(jobsite_id, opts) do
      {:ok, jobsite_id}
    end
  end

  defp resume_child(jobsite_id, opts) do
    case Supervisor.resume_jobsite(jobsite_id, Keyword.take(opts, [:max_concurrent, :prompt])) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, start_failed_error(reason)}
    end
  end

  @max_resume_prompt_chars 8_000

  # `nil` means "use the default continuation prompt"; anything else must be a
  # real operator message, bounded so it cannot bloat an agent request.
  defp validate_resume_prompt(nil), do: :ok

  defp validate_resume_prompt(prompt) when is_binary(prompt) do
    cond do
      String.trim(prompt) == "" ->
        {:error, Error.new(:spec_option_invalid, "prompt must not be blank", %{key: "prompt"})}

      String.length(prompt) > @max_resume_prompt_chars ->
        {:error,
         Error.new(
           :spec_option_invalid,
           "prompt must be at most #{@max_resume_prompt_chars} characters",
           %{key: "prompt", max_chars: @max_resume_prompt_chars}
         )}

      true ->
        :ok
    end
  end

  defp validate_resume_prompt(_other),
    do: {:error, Error.new(:spec_option_invalid, "prompt must be a string", %{key: "prompt"})}

  @default_steer_timeout_ms 60_000

  @doc """
  Steer a jobsite with an operator message (steering v1: pause, then resume).

  * running (an executor is alive): request a pause with reason `"steer"`, wait
    for that executor to exit (bounded by `:timeout_ms`, default
    #{@default_steer_timeout_ms}), then `resume_async/2` with `prompt: text`. The
    message becomes the next iteration's prompt instead of `"Continue."`.
    `{:error, :steer_timeout}` if the executor has not exited in time; the pause
    request is withdrawn so a late pause cannot surprise the operator. A jobsite
    that could not be resumed afterwards (`Executor.check_resumable/1`: e.g. its
    agent has not reported a provider session yet, `:no_session`) is refused
    BEFORE anything is paused, so a steer that was bound to fail never costs the
    running agent; retry once the session is bound.
  * paused (or crashed, non-terminal): `resume_async/2` directly.

  Returns `{:ok, jobsite_id}` once the resume has been accepted.
  """
  @spec steer(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, Error.t() | :steer_timeout | {:not_steerable, String.t()}}
  def steer(jobsite_id, text, opts \\ []) when is_binary(jobsite_id) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_steer_timeout_ms)

    with :ok <- validate_steer_text(text),
         :ok <- fetch_steerable(jobsite_id) do
      resume_opts = Keyword.take(opts, [:max_concurrent]) ++ [prompt: text]

      case ForemanServer.Jobsite.Executor.pid_for(jobsite_id) do
        nil ->
          resume_async(jobsite_id, resume_opts)

        pid ->
          with {:ok, _state} <- ForemanServer.Jobsite.Executor.check_resumable(jobsite_id) do
            pause_then_resume(jobsite_id, pid, resume_opts, timeout_ms)
          end
      end
    end
  end

  defp validate_steer_text(text) when is_binary(text), do: validate_resume_prompt(text)

  defp validate_steer_text(_other),
    do: {:error, Error.new(:spec_option_invalid, "prompt must be a string", %{key: "prompt"})}

  defp fetch_steerable(jobsite_id) do
    case get(jobsite_id) do
      nil ->
        {:error,
         Error.new(:jobsite_not_found, "jobsite #{jobsite_id} does not exist", %{
           jobsite_id: jobsite_id
         })}

      %{terminal?: true, status: status} ->
        {:error, {:not_steerable, status}}

      _live_or_paused ->
        :ok
    end
  end

  defp pause_then_resume(jobsite_id, pid, resume_opts, timeout_ms) do
    ref = Process.monitor(pid)
    :ok = pause(jobsite_id, "steer")

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
        case get(jobsite_id) do
          %{terminal?: true, status: status} -> {:error, {:not_steerable, status}}
          _paused_or_crashed -> resume_async(jobsite_id, resume_opts)
        end
    after
      timeout_ms ->
        Process.demonitor(ref, [:flush])
        Control.clear(jobsite_id)
        {:error, :steer_timeout}
    end
  end

  # `jobsite.pause` is dispatched before the Executor process exits, so a jobsite
  # projected `paused` can still have a live Executor for a few milliseconds. Wait
  # briefly for it to go; a jobsite that is not paused is genuinely running and is
  # refused at once.
  @executor_exit_wait_ms 2_000

  defp require_not_running(jobsite_id) do
    if paused?(jobsite_id), do: await_executor_exit(jobsite_id, @executor_exit_wait_ms)

    if ForemanServer.Jobsite.Executor.pid_for(jobsite_id) == nil do
      :ok
    else
      {:error,
       Error.new(:already_running, "jobsite #{jobsite_id} is already running", %{
         jobsite_id: jobsite_id
       })}
    end
  end

  defp paused?(jobsite_id) do
    match?(%{status: status} when status in [:paused, "paused"], get(jobsite_id))
  end

  # The Registry drops a dead process's entry asynchronously, so `:DOWN` does not
  # yet guarantee `pid_for/1` is nil: re-check until the deadline.
  defp await_executor_exit(jobsite_id, remaining_ms) do
    case ForemanServer.Jobsite.Executor.pid_for(jobsite_id) do
      nil ->
        :ok

      _pid when remaining_ms <= 0 ->
        :ok

      pid ->
        started = System.monotonic_time(:millisecond)
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} ->
            Process.sleep(1)
            elapsed = System.monotonic_time(:millisecond) - started
            await_executor_exit(jobsite_id, remaining_ms - elapsed)
        after
          remaining_ms ->
            Process.demonitor(ref, [:flush])
            :ok
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

      {:error, failure} ->
        {:error, Git.merge_error(repo_path, branch, failure)}
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
      {:ok, pid} ->
        ref = Process.monitor(pid)

        receive do
          {:jobsite, ^jobsite_id, outcome} ->
            Process.demonitor(ref, [:flush])
            outcome

          {:DOWN, ^ref, :process, ^pid, reason} ->
            # The executor reports to us before it exits; drain that message if it
            # raced ahead of the DOWN, otherwise the executor died without reporting.
            receive do
              {:jobsite, ^jobsite_id, outcome} -> outcome
            after
              0 ->
                {:error,
                 Error.new(
                   :executor_exited,
                   "jobsite executor exited before reporting a result",
                   %{reason: inspect(reason)}
                 )}
            end
        end

      {:error, reason} ->
        {:error, start_failed_error(reason)}
    end
  end

  defp start_failed_error({:capacity_reached, running, max}) do
    Error.new(:jobsite_capacity_reached, "#{running} jobsites already running (max #{max})", %{
      running: running,
      max: max
    })
  end

  defp start_failed_error({:already_started, _pid}) do
    Error.new(:already_running, "jobsite executor is already running", %{})
  end

  defp start_failed_error(reason) do
    Error.new(:dispatch_rejected, "failed to start jobsite executor", %{reason: reason})
  end

  defp executor_died_error({:executor_exited_before_start, exit_reason}) do
    Error.new(
      :jobsite_start_failed,
      "jobsite executor exited before recording its start",
      %{reason: {:executor_exited_before_start, exit_reason}}
    )
  end

  defp generate_id do
    "js-" <> (16 |> div(2) |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower))
  end
end
