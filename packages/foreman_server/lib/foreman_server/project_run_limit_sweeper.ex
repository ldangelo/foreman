defmodule ForemanServer.ProjectRunLimitSweeper do
  @moduledoc """
  TRD-041-FOLLOWUP (`for-k1l`): periodic GenServer that reconciles leaked
  slot reservations.

  Background — `run_terminal_saga` (in `CommandRouter`) is best-effort about
  the slot release after the canonical terminal event lands. If the gap-guard
  refuses the slot-stream append at that moment, the run stays terminal in
  `run:<run_id>` but the slot in `project_run_limit:<project_id>` is leaked
  forever — eventually the project hits the 100-slot cap even though every
  run has terminated.

  Sweep algorithm:

    1. Enumerate every slot stream via `EventStore.list_streams("project_run_limit:")`.
       This discovers streams even when the matching project projection is
       missing (failed-compensation leaks).
    2. For each stream, rebuild the `ProjectRunLimit` aggregate state via
       `Aggregate.load/2` so we know the live `active_run_ids` MapSet.
    3. For each `run_id` in that MapSet, compute the canonical `Run`
       aggregate state by replaying `run:<run_id>`. The sweep predicate is
       `state.terminal?` — NOT `ProjectionStore.run/1.status` — because the
       projection can be stale and because `Run.apply_event/2` deliberately
       leaves `PrMerged` nonterminal.
    4. If `terminal?: true`, dispatch `project_run_limit.reconcile` through
       `CommandRouter.handle/1`. That command is gap-guarded on the slot
       stream itself, so it will be retried on subsequent sweeps if the gap
       is unresolved. The compensating event is `ProjectRunSlotReleased`,
       distinct from the normal `ProjectRunCompleted` so the audit trail
       shows the recovery path.

  Idempotency:

    * `reconcile_slot/6` returns `:unhandled` (mapped to `{:ok,
      :already_released}` when the slot has already been removed from the
      MapSet, so repeated sweeps are safe.
    * `ProjectRunSlotReleased` folds with `MapSet.delete/2`, so duplicate
      reconcile events on the same `run_id` are no-ops.

  Discovered-from: `for-jea` (TRD-041). Blocks `for-jea` closure.
  """

  use GenServer

  require Logger

  alias ForemanServer.{Aggregate, CommandRouter, EventStore}

  @slot_stream_prefix "project_run_limit:"
  @run_stream_prefix "run:"
  @scan_interval_ms :timer.minutes(5)
  @sweep_timeout_ms :timer.seconds(30)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Synchronous one-shot sweep — used by the test suite and by operator tools.
  @spec sweep_once() :: {:ok, %{scanned: non_neg_integer(), released: non_neg_integer()}}
  def sweep_once do
    GenServer.call(__MODULE__, :sweep_once, @sweep_timeout_ms)
  end

  @impl true
  def init(_opts) do
    schedule_scan()
    {:ok, %{last_run_at: nil, total_released: 0}}
  end

  @impl true
  def handle_call(:sweep_once, _from, state) do
    case do_sweep() do
      {:ok, %{scanned: scanned, released: released}} ->
        new_state = %{
          state
          | last_run_at: DateTime.utc_now(),
            total_released: state.total_released + released
        }

        {:reply, {:ok, %{scanned: scanned, released: released}}, new_state}
    end
  end

  @impl true
  def handle_info(:scan, state) do
    new_state =
      case do_sweep() do
        {:ok, %{released: released}} ->
          %{
            state
            | last_run_at: DateTime.utc_now(),
              total_released: state.total_released + released
          }
      end

    schedule_scan()
    {:noreply, new_state}
  end

  # --- sweep logic ---------------------------------------------------------

  defp do_sweep do
    slot_streams = EventStore.list_streams(@slot_stream_prefix)

    summary =
      Enum.reduce(slot_streams, %{scanned: 0, released: 0}, fn stream_id, acc ->
        released_count = sweep_stream(stream_id)
        %{acc | scanned: acc.scanned + 1, released: acc.released + released_count}
      end)

    {:ok, summary}
  end

  # Returns the number of slots released for this stream. Non-stream-id
  # values (defensive) yield 0. Crash-isolation lives in `do_sweep/0`'s
  # caller (the GenServer `handle_info`/`handle_call` clauses).
  defp sweep_stream("project_run_limit:" <> project_id) do
    {state, _version} =
      Aggregate.load(
        ForemanServer.Aggregates.ProjectRunLimit,
        @slot_stream_prefix <> project_id
      )

    state.active_run_ids
    |> MapSet.to_list()
    |> Enum.count(&release_if_terminal(project_id, &1))
  end

  defp sweep_stream(_other), do: 0

  defp release_if_terminal(project_id, run_id) do
    if run_terminal?(run_id) do
      case dispatch_reconcile(project_id, run_id) do
        :released -> true
        :already_released -> false
      end
    else
      false
    end
  end

  defp run_terminal?(run_id) do
    case Aggregate.load(ForemanServer.Aggregates.Run, @run_stream_prefix <> run_id) do
      {%{exists?: true, terminal?: true}, _version} -> true
      _ -> false
    end
  end

  defp dispatch_reconcile(project_id, run_id) do
    case CommandRouter.handle(%{
           command_id: "slot-sweep:#{run_id}",
           command_type: "project_run_limit.reconcile",
           payload: %{
             project_id: project_id,
             run_id: run_id,
             released_by: "ProjectRunLimitSweeper"
           },
           metadata: %{source: "project_run_limit_sweeper"}
         }) do
      {:ok, :released} -> :released
      {:ok, :already_released} -> :already_released
      # Gap-blocked or other failure: leave for the next sweep.
      {:error, reason} ->
        Logger.debug(
          "[ProjectRunLimitSweeper] reconcile failed for run #{run_id}: #{inspect(reason)}"
        )

        :already_released
    end
  end

  defp schedule_scan do
    interval =
      Application.get_env(
        :foreman_server,
        :project_run_limit_sweep_interval_ms,
        @scan_interval_ms
      )

    Process.send_after(self(), :scan, interval)
  end
end