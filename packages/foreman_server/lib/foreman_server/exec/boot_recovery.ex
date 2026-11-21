defmodule ForemanServer.Exec.BootRecovery do
  @moduledoc """
  One-shot boot closer of the jobsite door's stranded jobsites (docs/plans/retire-jobsites.md §6).

  The jobsite dispatch path is retired: a PR fix now runs as a follow-up run, so nothing can start
  or resume a jobsite any more. A jobsite that a server restart or crash left non-terminal (running,
  starting or paused) would otherwise show as live to Threads and the Overview forever. At boot this
  closer records each such jobsite as FAILED with code `jobsite_retired`.

  Its worktree and branch stay on disk: nothing is force-deleted (CLAUDE.md §12, clean-vs-dirty
  rule), and the `jobsite:` streams stay readable forever (the fold and projections are kept).

  Per jobsite, decided from the authoritative aggregate (not the projection):

    * terminal, or unknown to the event store: untouched.
    * anything else (`starting`, `running`, `paused`): `jobsite.fail` with `code: "jobsite_retired"`.

  Commands are system commands through `CommandGateway.dispatch_system/1` with a command id derived
  from the jobsite id and the stream version the scan observed, so re-running over an unchanged
  stream is a no-op.

  Candidates are the event store's `jobsite:` streams, not `ProjectionStore.list_jobsites/0`: a
  projection whose boot replay failed is empty, and an empty candidate list must never mean
  "nothing to close". Failing to list the streams is logged at error and returned as
  `{:error, %Error{code: :boot_recovery_failed}}`. A failure to close one jobsite is logged at
  error with its id and does not stop the others or application boot.
  """

  use GenServer, restart: :temporary

  require Logger

  alias EventStore.Page
  alias EventStore.Streams.StreamInfo
  alias ForemanServer.{Aggregate, CommandGateway, EventStore}
  alias ForemanServer.Aggregates.Jobsite, as: JobsiteAggregate
  alias ForemanServer.Exec.Error

  @retired_code "jobsite_retired"
  @stream_prefix "jobsite:"
  @stream_page_size 100

  @type outcome ::
          {:failed, String.t()}
          | {:skipped, String.t(), :absent | :terminal}
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
       do: ForemanServer.Exec.NetworkPolicy.sweep_orphans()

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

  defp decide(jobsite_id, _state, version, dispatch) do
    "jobsite.fail"
    |> command(jobsite_id, version, %{
      code: @retired_code,
      message:
        "the jobsite dispatch path was retired; this jobsite was still open at server start " <>
          "and can no longer be resumed (its worktree and branch are kept)",
      details: %{jobsite_id: jobsite_id}
    })
    |> dispatch.()
    |> outcome(jobsite_id, :failed)
  end

  defp command(type, jobsite_id, version, payload) do
    %{
      type: type,
      command_id: "jobsite:#{jobsite_id}:#{type}:#{@retired_code}:v#{version}",
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
    failed = for {:failed, id} <- outcomes, do: id

    if failed != [] do
      Logger.warning(
        "Jobsite boot closer: #{length(failed)} open jobsite(s) closed as jobsite_retired: " <>
          "#{inspect(failed)}"
      )
    end

    :ok
  end
end
