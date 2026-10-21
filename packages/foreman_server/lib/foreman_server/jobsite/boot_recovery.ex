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

  Candidates are the event store's `jobsite:` streams, not
  `ProjectionStore.list_jobsites/0`: a projection whose boot replay failed is
  empty, and an empty candidate list must never mean "nothing to recover".
  Failing to list the streams is logged at error and returned as
  `{:error, %Error{code: :boot_recovery_failed}}`.

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

  alias EventStore.Page
  alias EventStore.Streams.StreamInfo
  alias ForemanServer.{Aggregate, CommandGateway, EventStore}
  alias ForemanServer.Aggregates.Jobsite, as: JobsiteAggregate
  alias ForemanServer.Jobsite.{Error, Executor}

  @pause_reason "server_restart"
  @stream_prefix "jobsite:"
  @stream_page_size 100

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
    # Network-policy networks/sidecars of jobsites that died with the previous
    # node: at boot none of them is live, so every one is an orphan.
    if :foreman_server
       |> Application.get_env(:network_policy, [])
       |> Keyword.get(:sweep_on_boot, true),
       do: ForemanServer.Jobsite.NetworkPolicy.sweep_orphans()

    case scan() do
      {:ok, outcomes} -> log_summary(outcomes)
      {:error, %Error{}} -> :ok
    end

    {:stop, :normal, state}
  end

  @doc """
  Reconcile every non-terminal jobsite found in the event store's `jobsite:`
  streams (not the projection: a failed projection replay installs an empty
  read model). Returns one typed
  outcome per candidate, or `{:error, Error.t()}` (already logged) when the
  candidate list itself cannot be read.

  `dispatch` is the system-command dispatcher; it is injectable so a test can
  prove one jobsite's failure does not stop the rest.
  """
  @spec scan((map() -> {:ok, term()} | {:error, term()})) ::
          {:ok, [outcome()]} | {:error, Error.t()}
  def scan(dispatch \\ &CommandGateway.dispatch_system/1) when is_function(dispatch, 1) do
    with {:ok, jobsite_ids} <- candidate_ids() do
      outcomes =
        jobsite_ids
        |> Enum.map(&reconcile(&1, dispatch))
        |> Enum.reject(&match?({:skipped, _, :terminal}, &1))

      {:ok, outcomes}
    end
  end

  # Candidates come from the event store's `jobsite:` streams, not from
  # `ProjectionStore`: if the projection's boot replay failed it falls back to
  # an empty read model, which would read here as "no jobsites" and silently
  # skip every orphan. The aggregate load in `reconcile/2` filters out the
  # jobsites that are terminal, so listing every stream is safe; terminal ones
  # are dropped from the result to keep the outcome list about actionable ids.
  defp candidate_ids do
    with {:ok, stream_uuids} <- jobsite_stream_uuids(1, []) do
      {:ok, Enum.map(stream_uuids, &String.replace_prefix(&1, @stream_prefix, ""))}
    else
      {:error, reason} -> candidates_failed(reason)
    end
  catch
    :exit, reason -> candidates_failed(reason)
  end

  # `paginate_streams(search: term)` matches `%term%`, so the prefix is
  # re-checked. Sorting by `stream_uuid` keeps paging stable.
  defp jobsite_stream_uuids(page_number, acc) do
    opts = [
      search: @stream_prefix,
      page_number: page_number,
      page_size: @stream_page_size,
      sort_by: :stream_uuid
    ]

    case EventStore.paginate_streams(opts) do
      {:ok, %Page{entries: entries, total_pages: total_pages}} ->
        acc =
          Enum.reduce(entries, acc, fn %StreamInfo{stream_uuid: stream_uuid}, uuids ->
            if String.starts_with?(stream_uuid, @stream_prefix),
              do: [stream_uuid | uuids],
              else: uuids
          end)

        if page_number >= total_pages,
          do: {:ok, Enum.reverse(acc)},
          else: jobsite_stream_uuids(page_number + 1, acc)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp candidates_failed(reason) do
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
