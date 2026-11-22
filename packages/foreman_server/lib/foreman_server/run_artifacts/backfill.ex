defmodule ForemanServer.RunArtifacts.Backfill do
  @moduledoc """
  One-shot boot pass that gives the reports recorded before the archive existed the copy
  `RunExecutor.phase_finish/5` now makes when a phase completes (`ForemanServer.RunArtifacts`).

  It is started once, after `ProjectionStore` has rebuilt its read model from the event log (a
  child listed after the store starts only once the store's `init/1` returned), so every recorded
  report is in the projection. It works in its own process: `init/1` returns at once and the pass
  runs in `handle_continue/2`, so it does not delay boot, and the child is `restart: :temporary`,
  so a crash is logged and never restarted or counted against the application's restart budget.
  It stops `:normal` when the pass is over.

  For every phase of every run that recorded an artifact (`RunArtifacts.list/2`, the one reader of
  that recorded shape), exactly one of these happens:

    * an archive copy exists: counted as already archived; the report is not read.
    * the recorded file is gone (its worktree was reclaimed before there was an archive): counted
      missing. There is nothing left to keep, and the run keeps answering `state: "missing"`.
    * the recorded file exists and hashes to the recorded `sha256`: copied and counted archived.
    * the recorded file exists but hashes to something else (it was edited after the phase
      finished): not archived, counted mismatched, logged at debug level with both hashes (it can
      never be archived, so a warning would repeat on every boot).
    * anything else (an unreadable file, an archive directory that cannot be written): warned
      about and counted failed.

  A failure on one report is a warning and never stops the pass or the server, and re-running the
  pass changes nothing: what is archived is skipped. The pass is bounded by the projection: each
  recorded report is visited once and streamed in constant memory, and nothing but the recorded
  paths is looked at. It ends with one info line:

      Run artifact backfill: archived N, already archived M, missing K, mismatched J, failed F

  Gated by `config :foreman_server, :start_run_artifact_backfill?` (default `true`; the test
  environment turns it off and its tests call `run/1`).
  """

  use GenServer, restart: :temporary

  require Logger

  alias ForemanServer.ProjectionStore
  alias ForemanServer.RunArtifacts
  alias ForemanServer.RunArtifacts.Entry
  alias ForemanServer.Workflow.RunExecutor

  defmodule Summary do
    @moduledoc "How the recorded reports of one backfill pass ended up, one count per outcome."

    @enforce_keys [:archived, :already_archived, :missing, :mismatched, :failed]
    @type t :: %__MODULE__{
            archived: non_neg_integer(),
            already_archived: non_neg_integer(),
            missing: non_neg_integer(),
            mismatched: non_neg_integer(),
            failed: non_neg_integer()
          }
    defstruct [:archived, :already_archived, :missing, :mismatched, :failed]
  end

  @type outcome :: :archived | :already_archived | :missing | :mismatched | :failed

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(init_arg \\ []), do: GenServer.start_link(__MODULE__, init_arg)

  @impl true
  def init(_init_arg), do: {:ok, %{}, {:continue, :backfill}}

  @impl true
  def handle_continue(:backfill, state) do
    _ = run(RunExecutor.artifact_base())
    {:stop, :normal, state}
  end

  @doc """
  One pass over every report the projection records, archiving under `artifact_base`
  (`RunExecutor.artifact_base/0` at boot). Returns how the reports ended up, after logging the
  one-line summary, or `{:error, reason}` (already logged) when the projection cannot be read.
  """
  @spec run(String.t()) :: {:ok, Summary.t()} | {:error, term()}
  def run(artifact_base) when is_binary(artifact_base) do
    case run_ids() do
      {:ok, run_ids} ->
        summary = Enum.reduce(run_ids, empty_summary(), &backfill_run(&1, artifact_base, &2))
        log_summary(summary)
        {:ok, summary}

      {:error, reason} ->
        Logger.error("Run artifact backfill could not list the runs: #{reason}")
        {:error, reason}
    end
  end

  defp run_ids do
    {:ok, for(run <- ProjectionStore.list_runs(), do: Map.fetch!(run, :run_id))}
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  # A run whose phases cannot be read, or whose projection is broken (`RunArtifacts.list/2`
  # raises on an artifact without a path), is one failure and does not stop the pass.
  defp backfill_run(run_id, artifact_base, summary) do
    case recorded_entries(run_id) do
      {:ok, entries} ->
        Enum.reduce(entries, summary, fn entry, acc ->
          count(acc, backfill_entry(run_id, entry, artifact_base))
        end)

      {:error, reason} ->
        Logger.warning(
          "Run artifact backfill: run #{run_id} skipped, its phases cannot be read: #{reason}"
        )

        count(summary, :failed)
    end
  end

  defp recorded_entries(run_id) do
    {:ok, RunArtifacts.list(run_id, ProjectionStore.phases_for_run(run_id)).artifacts}
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  # The isolation boundary of one report: whatever goes wrong with it (an unsafe run id raises
  # `RunArtifacts.UnsafeRunId`) is a warning and a `:failed` count, never the end of the pass.
  @spec backfill_entry(String.t(), Entry.t(), String.t()) :: outcome()
  defp backfill_entry(run_id, %Entry{} = entry, artifact_base) do
    if File.regular?(RunArtifacts.archive_path(artifact_base, run_id, entry.index)) do
      :already_archived
    else
      archive(run_id, entry, artifact_base)
    end
  rescue
    exception ->
      Logger.warning(
        "Run artifact backfill: run #{run_id} phase #{entry.index}: report #{entry.path} " <>
          "was not archived: #{Exception.message(exception)}"
      )

      :failed
  end

  defp archive(run_id, entry, artifact_base) do
    case RunArtifacts.archive(artifact_base, run_id, entry.index, entry.path, entry.sha256) do
      {:ok, _archived_path} ->
        :archived

      :in_archive ->
        :already_archived

      {:error, :recorded_missing} ->
        :missing

      {:error, {:sha_mismatch, expected, actual}} ->
        # A report edited after its phase finished can never be archived, so it would warn on every
        # boot; the summary line carries the count.
        Logger.debug(
          "run #{run_id} phase #{entry.index}: report #{entry.path} was not archived: " <>
            "its SHA-256 is #{actual}, recorded #{expected}"
        )

        :mismatched

      {:error, reason} ->
        RunArtifacts.warn_not_archived(run_id, entry.index, entry.path, reason)
        :failed
    end
  end

  defp empty_summary,
    do: %Summary{archived: 0, already_archived: 0, missing: 0, mismatched: 0, failed: 0}

  defp count(%Summary{} = summary, :archived),
    do: %Summary{summary | archived: summary.archived + 1}

  defp count(%Summary{} = summary, :already_archived),
    do: %Summary{summary | already_archived: summary.already_archived + 1}

  defp count(%Summary{} = summary, :missing), do: %Summary{summary | missing: summary.missing + 1}

  defp count(%Summary{} = summary, :mismatched),
    do: %Summary{summary | mismatched: summary.mismatched + 1}

  defp count(%Summary{} = summary, :failed), do: %Summary{summary | failed: summary.failed + 1}

  defp log_summary(%Summary{} = summary) do
    Logger.info(
      "Run artifact backfill: archived #{summary.archived}, " <>
        "already archived #{summary.already_archived}, missing #{summary.missing}, " <>
        "mismatched #{summary.mismatched}, failed #{summary.failed}"
    )
  end
end
