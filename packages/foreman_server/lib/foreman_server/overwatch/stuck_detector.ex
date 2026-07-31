defmodule ForemanServer.Overwatch.StuckDetector do
  @moduledoc """
  Periodic stuck-run detector.

  Scans active runs every `stuck_run_check_interval_seconds` (default: 5 minutes)
  and flags any run that has not received a liveness event (phase/worker) for more
  than 15 minutes.  Detection events are dispatched through `CommandRouter` so the
  normal aggregate/ProjectionStore pipeline handles them idempotently.
  """

  use GenServer

  alias ForemanServer.CommandRouter
  alias ForemanServer.ProjectionStore

  @default_interval_seconds 5 * 60
  @stuck_threshold_seconds 15 * 60

  # ─── Client API ───────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # ─── GenServer callbacks ──────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    interval_seconds = Application.get_env(:foreman_server, :stuck_run_check_interval_seconds, @default_interval_seconds)
    interval_ms = interval_seconds * 1000
    schedule_scan(interval_ms)
    {:ok, %{interval_ms: interval_ms}}
  end

  @impl true
  def handle_info(:scan, state) do
    detect_stuck_runs()
    schedule_scan(state.interval_ms)
    {:noreply, state}
  end

  # ─── Detection ────────────────────────────────────────────────────────────

  defp detect_stuck_runs do
    %{runs: runs} = ProjectionStore.snapshot()

    now = DateTime.utc_now()

    runs
    |> active_non_stuck_runs()
    |> Enum.each(fn {run_id, run} ->
      # Prefer the most recent available timestamp.
      # last_event_time reflects the latest liveness event;
      # updated_at captures later state changes even if no liveness event fired;
      # started_at is the final fallback for newly created runs.
      effective_time =
        Map.get(run, :last_event_time) ||
          Map.get(run, :updated_at) ||
          Map.get(run, :started_at)

      if stale?(effective_time, now) do
        flag_stuck(run_id, effective_time, now)
      end
    end)
  end

  # Active = not in a terminal status and not already stuck.
  defp active_non_stuck_runs(runs) do
    Enum.filter(runs, fn {_run_id, run} ->
      status = Map.get(run, :status, "")
      status not in ["completed", "failed", "blocked", "merged", "deleted", "stuck"]
    end)
  end

  defp stale?(nil, _now), do: true
  defp stale?(%DateTime{} = last_event_time, now) do
    DateTime.diff(now, last_event_time, :second) > @stuck_threshold_seconds
  end
  defp stale?(last_event_time, now) when is_binary(last_event_time) do
    case DateTime.from_iso8601(last_event_time) do
      {:ok, parsed, _} -> DateTime.diff(now, parsed, :second) > @stuck_threshold_seconds
      _ -> true
    end
  end

  defp flag_stuck(run_id, last_event_time, now) do
    case CommandRouter.handle(%{
           command_id: "stuck:#{run_id}:#{System.system_time(:second)}",
           command_type: "run.flag_stuck",
           payload: %{
             run_id: run_id,
             last_event_time: last_event_time,
             flagged_at: now,
             source: "stuck_detector"
           }
         }) do
      {:ok, _result} ->
        :telemetry.execute([:foreman, :run, :stuck], %{run_id: run_id}, %{run_id: run_id, flagged_at: now})

      {:error, :already_stuck} ->
        # Benign race: another scanner beat us to it
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp schedule_scan(interval_ms) do
    Process.send_after(self(), :scan, interval_ms)
  end
end
