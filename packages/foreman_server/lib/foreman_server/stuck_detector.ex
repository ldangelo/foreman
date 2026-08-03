defmodule ForemanServer.StuckDetector do
  @moduledoc """
  Periodic scanner that flags runs whose last activity is older than
  `threshold_ms` (default 15 minutes).

  For each stuck run the detector:

    1. Emits `[:foreman, :run, :stuck]` telemetry BEFORE dispatching.
    2. Dispatches a `run.flag_stuck` command via `CommandRouter`.

  The `RunFlaggedStuck` event persisted by `CommandRouter` flips the run
  projection to `status: "stuck"`, `terminal?: true`. Because
  `CommandRouter` calls `ProjectionStore.apply_events/1` before returning
  to the caller, the next tick will not re-flag the same run.
  """

  use GenServer

  alias ForemanServer.{CommandRouter, ProjectionStore, Telemetry}

  @default_threshold_ms 900_000
  @default_interval_seconds 60
  @default_dispatch_timeout 5_000
  @app :foreman_server

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  One-shot scan. Returns a list of `%{run_id, idle_ms, dispatch: :ok | {:error, term}}`
  for every active run whose last activity exceeds `threshold_ms`.
  """
  @spec scan(keyword()) :: [%{run_id: String.t(), idle_ms: non_neg_integer(), dispatch: term()}]
  def scan(opts \\ []) do
    threshold_ms = Keyword.get(opts, :threshold_ms, @default_threshold_ms)
    now_ms_fun = Keyword.get(opts, :now_ms_fun, &System.system_time/1)
    dispatch_fun = Keyword.get(opts, :dispatch_fun, &CommandRouter.dispatch/2)
    dispatch_timeout = Keyword.get(opts, :dispatch_timeout, @default_dispatch_timeout)

    now_ms = now_ms_fun.()

    ProjectionStore.stuck_runs(threshold_ms, now_ms)
    |> Enum.map(fn run_id ->
      idle_ms = idle_for(run_id, now_ms)
      Telemetry.run_stuck(idle_ms, threshold_ms, run_id)

      cmd = %{
        aggregate_id: "run:#{run_id}",
        type: "run.flag_stuck",
        payload: %{run_id: run_id, flagged_at: now_ms}
      }

      result =
        try do
          dispatch_fun.(cmd, dispatch_timeout)
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      %{run_id: run_id, idle_ms: idle_ms, dispatch: dispatch_status(result)}
    end)
  end

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, default_interval_ms())
    threshold_ms = Keyword.get(opts, :threshold_ms, @default_threshold_ms)

    schedule_scan(interval_ms)

    {:ok,
     %{
       opts: opts,
       interval_ms: interval_ms,
       threshold_ms: threshold_ms
     }}
  end

  @impl true
  def handle_info(:scan, state) do
    _results = scan(state.opts)
    schedule_scan(state.interval_ms)
    {:noreply, state}
  end

  # -------------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------------

  defp schedule_scan(interval_ms) do
    Process.send_after(self(), :scan, interval_ms)
  end

  defp idle_for(run_id, now_ms) do
    case ProjectionStore.run_projection(run_id) do
      %{last_event_at_ms: last} when is_integer(last) -> max(now_ms - last, 0)
      _ -> 0
    end
  end

  defp dispatch_status({:ok, _}), do: :ok
  defp dispatch_status({:error, _} = err), do: err

  defp default_interval_ms do
    Application.get_env(@app, :stuck_run_check_interval_seconds, @default_interval_seconds) * 1000
  end
end
