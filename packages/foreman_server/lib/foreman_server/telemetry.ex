defmodule ForemanServer.Telemetry do
  @moduledoc false

  @command_dispatch [:foreman, :command, :dispatch]
  @aggregate_rehydrated [:foreman, :aggregate, :rehydrated]
  @worker_heartbeat [:foreman, :worker, :heartbeat]
  @worker_exit [:foreman, :worker, :exit]

  @all_events [
    @command_dispatch,
    @aggregate_rehydrated,
    @worker_heartbeat,
    @worker_exit
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
end
