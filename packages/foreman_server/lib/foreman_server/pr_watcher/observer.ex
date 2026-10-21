defmodule ForemanServer.PrWatcher.Observer do
  @moduledoc """
  One observation of one PR: fetch it once, then turn what changed into Run
  commands for every run that owns the PR.

  This is the single code path shared by `ForemanServer.PrWatcher` (events,
  webhooks), `ForemanServer.PrMonitor` (the poll) and the fix reactor's
  re-observation after a fix push, so a poll, a webhook and a push converge on
  identical, deterministic command ids (`ForemanServer.PrObservation`) and the
  router collapses duplicates.

  Per run it dispatches, through `CommandGateway.dispatch_system/1`:

    * the commands `PrObservation.commands/4` derives from the reading against
      the run's stored watch record;
    * `run.pr.watch_stop` when GitHub reports the PR merged or closed (the watch
      ends; polling stops; a merged PR is resolved by `Overview.MergeResolver`
      from the same `PrUpdated`);
    * `run.pr.watch_start` when a PR whose watch ended as `closed` is seen open
      again (a reopened PR resumes at the poll interval).

  A watch that an operator stopped (`stop_reason: "operator"`) is never
  restarted by observation, and observation of it is skipped entirely.
  A dispatch that is rejected is returned as an error and logged, never counted
  as success (see `ForemanServer.PrMonitor`).
  """

  alias ForemanServer.CommandGateway
  alias ForemanServer.GitHub.PrStatus
  alias ForemanServer.PrObservation
  alias ForemanServer.ProjectionStore

  require Logger

  @type result :: %{
          status: PrStatus.t(),
          runs: [String.t()],
          dispatched: [String.t()]
        }

  @type error ::
          :not_watched
          | PrStatus.error()
          | {:dispatch_failed, [{String.t(), String.t(), term()}]}
          | PrObservation.error()

  @doc """
  Observe `pr_url` once.

  Options: `:fetch_fun` (`(pr_url -> {:ok, PrStatus.t()} | {:error, term()})`,
  default reads checks, reviews, comments and review threads through `gh`).
  Returns `{:error, :not_watched}` when no run owns the PR or every owner's
  watch was stopped by the operator.
  """
  @spec observe(String.t(), keyword()) :: {:ok, result()} | {:error, error()}
  def observe(pr_url, opts \\ []) when is_binary(pr_url) do
    fetch = Keyword.get(opts, :fetch_fun, &default_fetch/1)

    case observable_runs(pr_url) do
      [] ->
        {:error, :not_watched}

      runs ->
        with {:ok, %PrStatus{} = status} <- safe_fetch(fetch, pr_url) do
          dispatch_for_runs(runs, pr_url, status)
        end
    end
  end

  @doc "The default fetch: one `gh pr view`, plus review threads when reviews exist."
  @spec default_fetch(String.t()) :: {:ok, PrStatus.t()} | {:error, PrStatus.error()}
  def default_fetch(pr_url), do: PrStatus.fetch(pr_url, threads: true)

  # Runs that own the PR and whose watch is on (or reopenable: ended as `closed`).
  defp observable_runs(pr_url) do
    pr_url
    |> ProjectionStore.run_ids_for_pr_url()
    |> Enum.map(&{&1, watch_record(&1, pr_url)})
    |> Enum.filter(fn {_run_id, record} -> observable?(record) end)
  end

  defp watch_record(run_id, pr_url),
    do: run_id |> ProjectionStore.pr_watch() |> Enum.find(&(&1.pr_url == pr_url))

  defp observable?(nil), do: true
  defp observable?(%{watching: true}), do: true
  defp observable?(%{stop_reason: "closed"}), do: true
  defp observable?(_stopped_by_operator_or_merged), do: false

  defp safe_fetch(fetch, pr_url) do
    fetch.(pr_url)
  rescue
    error ->
      Logger.warning("PrWatcher fetch crashed for #{pr_url}: #{Exception.message(error)}")
      {:error, {:fetch_crashed, Exception.message(error)}}
  end

  defp dispatch_for_runs(runs, pr_url, status) do
    {dispatched, failures} =
      Enum.reduce(runs, {[], []}, fn {run_id, record}, acc ->
        case dispatch_run(run_id, record, pr_url, status) do
          {:ok, types} -> {elem(acc, 0) ++ types, elem(acc, 1)}
          {:error, run_failures} -> {elem(acc, 0), elem(acc, 1) ++ run_failures}
        end
      end)

    case failures do
      [] ->
        {:ok, %{status: status, runs: Enum.map(runs, &elem(&1, 0)), dispatched: dispatched}}

      failures ->
        {:error, {:dispatch_failed, failures}}
    end
  end

  defp dispatch_run(run_id, record, pr_url, status) do
    with {:ok, observation} <- PrObservation.commands(run_id, pr_url, status, record) do
      commands = observation ++ lifecycle_commands(run_id, record, pr_url, status)

      results = for command <- commands, do: {command, CommandGateway.dispatch_system(command)}

      case for {command, {:error, reason}} <- results, do: {run_id, command.type, reason} do
        [] ->
          {:ok, Enum.map(commands, & &1.type)}

        failures ->
          Logger.error("PrWatcher run_id=#{run_id} url=#{pr_url} rejected: #{inspect(failures)}")
          {:error, failures}
      end
    else
      {:error, reason} ->
        Logger.warning("PrWatcher run_id=#{run_id} url=#{pr_url}: #{inspect(reason)}")
        {:error, [{run_id, "observation", reason}]}
    end
  end

  # Merged/closed ends the watch; open again after `closed` restarts it.
  defp lifecycle_commands(run_id, record, pr_url, %PrStatus{status: terminal} = status)
       when terminal in [:merged, :closed] do
    if record == nil or record.watching do
      [
        watch_command(
          "run.pr.watch_stop",
          run_id,
          record,
          pr_url,
          status,
          Atom.to_string(terminal)
        )
      ]
    else
      []
    end
  end

  defp lifecycle_commands(
         run_id,
         %{watching: false, stop_reason: "closed"} = record,
         pr_url,
         status
       ),
       do: [watch_command("run.pr.watch_start", run_id, record, pr_url, status, "reopened")]

  defp lifecycle_commands(_run_id, _record, _pr_url, _status), do: []

  # The record's last-update time is part of the id so a second close/reopen cycle
  # on the same head SHA is a new command, not a swallowed duplicate.
  defp watch_command(type, run_id, record, pr_url, status, reason) do
    cycle = (record && record.updated_at) || 0

    %{
      type: type,
      command_id:
        "#{String.replace(type, ".", "_")}:#{run_id}:#{PrObservation.url_hash(pr_url)}:#{reason}:#{status.head_sha}:#{cycle}",
      aggregate_id: "run:#{run_id}",
      payload: %{run_id: run_id, pr_url: pr_url, reason: reason}
    }
  end
end
