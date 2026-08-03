defmodule ForemanServer.Telemetry do
  @moduledoc false

  @command_dispatch [:foreman, :command, :dispatch]
  @aggregate_rehydrated [:foreman, :aggregate, :rehydrated]
  @worker_heartbeat [:foreman, :worker, :heartbeat]
  @worker_exit [:foreman, :worker, :exit]
  @run_stuck [:foreman, :run, :stuck]

  @all_events [
    @command_dispatch,
    @aggregate_rehydrated,
    @worker_heartbeat,
    @worker_exit,
    @run_stuck
  ]

  def all_events, do: @all_events

  def execute(event, measurements, metadata \\ %{}) do
    :telemetry.execute(event, measurements, metadata)
  end

  def attach_many(handler_id, events, handler, config \\ nil) do
    :telemetry.attach_many(handler_id, events, handler, config)
  end

  def command_dispatch(duration_ms, append_latency_ms, status, aggregate_id) do
    execute(@command_dispatch, %{duration_ms: duration_ms, append_latency_ms: append_latency_ms}, %{
      status: status,
      aggregate_id: aggregate_id
    })
  end

  def aggregate_rehydrated(event_count) do
    execute(@aggregate_rehydrated, %{event_count: event_count}, %{})
  end

  def worker_heartbeat(measurements \\ %{count: 1}, metadata \\ %{}) do
    execute(@worker_heartbeat, measurements, metadata)
  end

  def worker_exit(measurements \\ %{count: 1}, metadata \\ %{}) do
    execute(@worker_exit, measurements, metadata)
  end

  @doc """
  Emits `[:foreman, :run, :stuck]` when StuckDetector flags a run.

  Measurements:
    * `:idle_ms` — wall-clock milliseconds since the run's last event
      (last phase or worker heartbeat).

  Metadata:
    * `:run_id` — the run that has been flagged.
    * `:threshold_ms` — the threshold the detector compared against.
  """
  @spec run_stuck(non_neg_integer(), non_neg_integer(), String.t()) :: :ok
  def run_stuck(idle_ms, threshold_ms, run_id)
      when is_integer(idle_ms) and idle_ms >= 0 and is_binary(run_id) do
    execute(@run_stuck, %{idle_ms: idle_ms}, %{
      run_id: run_id,
      threshold_ms: threshold_ms
    })
  end
end
