defmodule ForemanServer.StallDetector do
  @moduledoc """
  Periodic phase-level stall scanner.

  Reads canonical projection candidates and persists a `RunStallReported` fact
  through the run aggregate. Worker heartbeats are not activity for this detector.
  """

  use GenServer

  alias ForemanServer.{CommandGateway, ProjectionStore, RunExecutorLiveness}
  alias ForemanServer.Workflow.RunExecutor

  @default_interval_seconds 60
  @default_dispatch_timeout 5_000
  @app :foreman_server

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec scan(keyword()) :: [map()]
  def scan(opts \\ []) do
    now_ms_fun = Keyword.get(opts, :now_ms_fun, fn -> System.system_time(:millisecond) end)
    dispatch_fun = Keyword.get(opts, :dispatch_fun, &CommandGateway.dispatch_system/2)
    dispatch_timeout = Keyword.get(opts, :dispatch_timeout, @default_dispatch_timeout)
    now_ms = now_ms_fun.()

    candidates = ProjectionStore.stall_candidates(now_ms)

    {exempted, reportable} = Enum.split_with(candidates, &live_within_deadline?(&1, now_ms))

    :telemetry.execute(
      [:foreman, :run, :stall_detector, :scan],
      %{
        candidates: length(candidates),
        reportable: length(reportable),
        exempted: length(exempted)
      },
      %{}
    )

    Enum.map(reportable, fn candidate ->
      :telemetry.execute(
        [:foreman, :run, :stall_detected],
        %{idle_ms: candidate.idle_ms, threshold_ms: candidate.threshold_ms},
        Map.take(candidate, [:run_id, :phase_id, :stall_kind, :policy])
      )

      cmd = %{
        aggregate_id: "run:#{candidate.run_id}",
        type: "run.report_stall",
        payload: candidate
      }

      result =
        try do
          dispatch_fun.(cmd, dispatch_timeout)
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      Map.put(candidate, :dispatch, dispatch_status(result))
    end)
  end

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, default_interval_ms())
    schedule_scan(interval_ms)
    {:ok, %{opts: opts, interval_ms: interval_ms}}
  end

  @impl true
  def handle_info(:scan, state) do
    if ForemanServer.Workflow.StallPolicy.enabled?(), do: scan(state.opts)
    schedule_scan(state.interval_ms)
    {:noreply, state}
  end

  defp schedule_scan(interval_ms), do: Process.send_after(self(), :scan, interval_ms)

  defp live_within_deadline?(%{stall_kind: "agent_no_output", run_id: run_id}, now_ms) do
    with pid when is_pid(pid) <- RunExecutor.pid_for(run_id),
         true <- Process.alive?(pid),
         {:active, ^pid, _deadline} <- RunExecutorLiveness.lookup(run_id, now_ms) do
      true
    else
      _ -> false
    end
  end

  defp live_within_deadline?(_candidate, _now_ms), do: false

  defp dispatch_status({:ok, _}), do: :ok
  defp dispatch_status({:error, _} = err), do: err

  defp default_interval_ms do
    Application.get_env(@app, :stall_detection_check_interval_seconds, @default_interval_seconds) *
      1000
  end
end
