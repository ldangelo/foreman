defmodule ForemanServer.Jobsite.BootRecovery do
  @moduledoc """
  One-shot boot scan that makes jobsites orphaned by a server restart visible
  and resumable.

  `Jobsite.Supervisor` starts executors as `:temporary`, so an executor killed
  by a restart or crash leaves its `jobsite:<id>` aggregate non-terminal
  forever (status `running`, often with an open `JobsiteIterationStarted`).
  At boot this scan finds every such jobsite and records it as paused with
  reason `"server_restart"`, so it shows as `paused` in
  `GET /api/jobsites` and is continued through the existing
  `Jobsite.resume/1` / `resume_async/2` / `POST /api/jobsites/:id/resume` path.

  It NEVER resumes anything itself: a resume starts an agent unattended,
  `agent.env` is deliberately not persisted, and remote start is gated by
  `allow_remote_start`. Recovery stays an explicit operator decision.

  Per jobsite, decided from the authoritative aggregate (not the projection):

    * terminal, already `paused`, or unknown to the event store — untouched.
    * has a live executor in `Jobsite.Registry` — untouched, so a scan racing
      a legitimate start never pauses a live run.
    * no worktree was ever provisioned (`starting`) — there is nothing for
      `resume` to continue, so it is failed with `:executor_lost` rather than
      left permanently non-terminal.
    * otherwise — `jobsite.pause` with `reason: "server_restart"`.

  Commands are system commands through `CommandGateway.dispatch_system/1`
  with a command id derived from the jobsite id and the stream version the
  scan observed. Re-running over an unchanged stream is therefore a no-op, yet
  a jobsite that is resumed and orphaned again by a later restart (a longer
  stream) gets a fresh id and is paused again.

  A failure to reconcile one jobsite is logged at error with its id and does
  not stop the others or application boot.

  Known residual window: the `Jobsite.Registry` check and the pause dispatch
  are not atomic (a few microseconds). That is acceptable here because the
  scan runs once at boot, before anything has started an executor in this
  VM; closing it would need `Jobsite.Supervisor`'s admission lock, which is
  not worth taking for a scan that cannot race a resume in practice.
  """

  use GenServer, restart: :temporary

  require Logger

  alias ForemanServer.{Aggregate, CommandGateway, ProjectionStore}
  alias ForemanServer.Aggregates.Jobsite, as: JobsiteAggregate
  alias ForemanServer.Jobsite.{Error, Executor}

  @pause_reason "server_restart"

  @type outcome ::
          {:paused, String.t()}
          | {:failed, String.t()}
          | {:skipped, String.t(), :absent | :terminal | :already_paused | :executor_live}
          | {:error, String.t(), Error.t()}

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(init_arg \\ []), do: GenServer.start_link(__MODULE__, init_arg)

  @impl true
  def init(_init_arg), do: {:ok, %{}, {:continue, :scan}}

  @impl true
  def handle_continue(:scan, state) do
    case scan() do
      {:ok, outcomes} -> log_summary(outcomes)
      {:error, %Error{}} -> :ok
    end

    {:stop, :normal, state}
  end

  @doc """
  Reconcile every non-terminal jobsite in the projection. Returns one typed
  outcome per candidate, or `{:error, Error.t()}` (already logged) when the
  candidate list itself cannot be read.

  `dispatch` is the system-command dispatcher; it is injectable so a test can
  prove one jobsite's failure does not stop the rest.
  """
  @spec scan((map() -> {:ok, term()} | {:error, term()})) ::
          {:ok, [outcome()]} | {:error, Error.t()}
  def scan(dispatch \\ &CommandGateway.dispatch_system/1) when is_function(dispatch, 1) do
    with {:ok, jobsite_ids} <- candidate_ids() do
      {:ok, Enum.map(jobsite_ids, &reconcile(&1, dispatch))}
    end
  end

  defp candidate_ids do
    ids =
      ProjectionStore.list_jobsites()
      |> Enum.reject(&(Map.get(&1, :terminal?) == true))
      |> Enum.map(& &1.jobsite_id)

    {:ok, ids}
  catch
    :exit, reason ->
      Logger.error("Jobsite boot recovery could not list jobsites: #{inspect(reason)}")

      {:error,
       Error.new(:boot_recovery_failed, "could not list jobsites", %{reason: inspect(reason)})}
  end

  # Isolation boundary: whatever goes wrong for one jobsite (event store read,
  # router exit, aggregate rejection) becomes a logged, typed `:error` outcome.
  defp reconcile(jobsite_id, dispatch) do
    {state, version} = Aggregate.load(JobsiteAggregate, "jobsite:" <> jobsite_id)
    decide(jobsite_id, state, version, dispatch)
  rescue
    exception -> reconcile_failed(jobsite_id, Exception.message(exception))
  catch
    :exit, reason -> reconcile_failed(jobsite_id, inspect(reason))
  end

  defp decide(jobsite_id, %{exists?: false}, _version, _dispatch),
    do: {:skipped, jobsite_id, :absent}

  defp decide(jobsite_id, %{terminal?: true}, _version, _dispatch),
    do: {:skipped, jobsite_id, :terminal}

  defp decide(jobsite_id, %{status: "paused"}, _version, _dispatch),
    do: {:skipped, jobsite_id, :already_paused}

  defp decide(jobsite_id, state, version, dispatch) do
    # Checked after the (slow) aggregate load, immediately before dispatching.
    if Executor.pid_for(jobsite_id) do
      {:skipped, jobsite_id, :executor_live}
    else
      recover(jobsite_id, state, version, dispatch)
    end
  end

  defp recover(jobsite_id, %{worktree_path: nil}, version, dispatch) do
    error =
      Error.new(
        :executor_lost,
        "executor lost at server restart before a worktree was provisioned; nothing to resume",
        %{jobsite_id: jobsite_id}
      )

    "jobsite.fail"
    |> command(jobsite_id, version, %{
      code: Atom.to_string(error.code),
      message: error.message,
      details: error.details
    })
    |> dispatch.()
    |> outcome(jobsite_id, :failed)
  end

  defp recover(jobsite_id, state, version, dispatch) do
    "jobsite.pause"
    |> command(jobsite_id, version, %{
      reason: @pause_reason,
      iteration_index: last_completed_index(state)
    })
    |> dispatch.()
    |> outcome(jobsite_id, :paused)
  end

  # Mirrors what `Executor` records on a pause: the last iteration that finished.
  defp last_completed_index(%{iteration_open?: true, iteration_index: index}), do: index - 1
  defp last_completed_index(%{iteration_index: index}), do: index

  defp command(type, jobsite_id, version, payload) do
    %{
      type: type,
      command_id: "jobsite:#{jobsite_id}:#{type}:#{@pause_reason}:v#{version}",
      aggregate_id: "jobsite:#{jobsite_id}",
      payload: Map.put(payload, :jobsite_id, jobsite_id)
    }
  end

  defp outcome({:ok, _}, jobsite_id, tag), do: {tag, jobsite_id}

  defp outcome({:error, reason}, jobsite_id, _tag),
    do: reconcile_failed(jobsite_id, inspect(reason))

  defp reconcile_failed(jobsite_id, reason) do
    Logger.error("Jobsite boot recovery failed for #{jobsite_id}: #{reason}")

    {:error, jobsite_id,
     Error.new(:boot_recovery_failed, "could not reconcile jobsite #{jobsite_id}", %{
       jobsite_id: jobsite_id,
       reason: reason
     })}
  end

  defp log_summary(outcomes) do
    paused = for {:paused, id} <- outcomes, do: id
    failed = for {:failed, id} <- outcomes, do: id

    if paused != [] or failed != [] do
      Logger.warning(
        "Jobsite boot recovery: #{length(paused)} jobsite(s) orphaned by server restart " <>
          "paused (resumable): #{inspect(paused)}; #{length(failed)} failed as unrecoverable: " <>
          "#{inspect(failed)}"
      )
    end

    :ok
  end
end
