defmodule ForemanServer.DebugViews do
  @moduledoc "Event-backed log, report, and debug timeline read views."

  alias ForemanServer.{Event, EventStore, ProjectionStore}

  @log_event_types MapSet.new([
                     "WorkerStdout",
                     "WorkerStderr",
                     "AssistantMessage",
                     "ToolCallFinished",
                     "WorkerStarted",
                     "WorkerHeartbeat",
                     "PhaseStarted",
                     "PhaseCompleted",
                     "PhaseFailed",
                     "PhaseTimedOut",
                     "PhaseRetried"
                   ])

  @timeline_event_types MapSet.new([
                          "RunStarted",
                          "RunCompleted",
                          "RunFailed",
                          "RunBlocked",
                          "PhaseStarted",
                          "PhaseCompleted",
                          "PhaseFailed",
                          "PhaseTimedOut",
                          "PhaseRetried",
                          "WorkerStarted",
                          "WorkerHeartbeat",
                          "WorkerStdout",
                          "WorkerStderr",
                          "AssistantMessage",
                          "ToolCallFinished",
                          "PrMerged",
                          "MergeFailed",
                          "MergeBlocked",
                          "WorkerFailureSimulated",
                          "WorkerRecoveryRequired",
                          "ExternalWorkerObserved",
                          "WorkerReattached",
                          "WorkerRestarted",
                          "NeedsOperator"
                        ])

  @spec logs(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def logs(run_id, opts \\ [])

  def logs(run_id, opts) when is_binary(run_id) and run_id != "" do
    mode = Keyword.get(opts, :mode, :compact)

    entries =
      run_id
      |> run_events()
      |> Enum.filter(&MapSet.member?(@log_event_types, &1.event_type))
      |> Enum.map(&log_entry(&1, mode))

    {:ok, %{run_id: run_id, mode: Atom.to_string(mode), entries: entries}}
  end

  def logs(_run_id, _opts), do: {:error, {:missing_or_invalid, :run_id}}

  @spec report(String.t()) :: {:ok, map()} | {:error, term()}
  def report(run_id) when is_binary(run_id) and run_id != "" do
    events = run_events(run_id)
    snapshot = ProjectionStore.snapshot()
    run = get_in(snapshot, [:runs, run_id]) || %{run_id: run_id, status: "unknown"}

    {:ok,
     %{
       run_id: run_id,
       status: Map.get(run, :status, "unknown"),
       current_phase: Map.get(run, :current_phase),
       phase_status: Map.get(run, :phase_status, %{}),
       artifact_paths: collect_paths(events, :artifact_paths),
       report_paths: collect_paths(events, :report_paths),
       failures: failure_entries(events),
       event_count: length(events),
       summary: summary(run, events)
     }}
  end

  def report(_run_id), do: {:error, {:missing_or_invalid, :run_id}}

  @spec debug_timeline(String.t()) :: {:ok, map()} | {:error, term()}
  def debug_timeline(run_id) when is_binary(run_id) and run_id != "" do
    events = run_events(run_id)

    {:ok, report} = report(run_id)

    timeline =
      events
      |> Enum.filter(&MapSet.member?(@timeline_event_types, &1.event_type))
      |> Enum.map(&timeline_entry/1)

    {:ok,
     %{
       run_id: run_id,
       timeline: timeline,
       artifacts: report.artifact_paths,
       reports: report.report_paths,
       failures: report.failures,
       summary: report.summary
     }}
  end

  def debug_timeline(_run_id), do: {:error, {:missing_or_invalid, :run_id}}

  defp run_events(run_id) do
    EventStore.all()
    |> Enum.filter(&(event_run_id(&1) == run_id or &1.correlation_id == run_id))
    |> Enum.sort_by(&{&1.occurred_at || DateTime.from_unix!(0), &1.stream_version || 0})
  end

  defp event_run_id(%Event{payload: payload}), do: Map.get(payload, :run_id)

  defp log_entry(%Event{} = event, :raw) do
    %{
      event_id: event.event_id,
      sequence: event.stream_version,
      type: event.event_type,
      stream_id: event.stream_id,
      occurred_at: event.occurred_at,
      payload: event.payload,
      metadata: event.metadata
    }
  end

  defp log_entry(%Event{} = event, _mode) do
    payload = event.payload

    %{
      event_id: event.event_id,
      sequence: event.stream_version,
      type: event.event_type,
      phase_id: Map.get(payload, :phase_id),
      worker_id: Map.get(payload, :worker_id),
      stream: stream_name(event.event_type),
      message: compact_message(event.event_type, payload),
      occurred_at: event.occurred_at
    }
  end

  defp timeline_entry(%Event{} = event) do
    payload = event.payload

    %{
      event_id: event.event_id,
      sequence: event.stream_version,
      type: event.event_type,
      phase_id: Map.get(payload, :phase_id),
      worker_id: Map.get(payload, :worker_id),
      status: Map.get(payload, :status),
      artifact_paths: Map.get(payload, :artifact_paths, []),
      report_paths: Map.get(payload, :report_paths, []),
      reason: Map.get(payload, :reason, Map.get(payload, :error)),
      occurred_at: event.occurred_at
    }
  end

  defp compact_message("WorkerStdout", payload), do: Map.get(payload, :output, "")
  defp compact_message("WorkerStderr", payload), do: Map.get(payload, :output, "")

  defp compact_message("AssistantMessage", payload),
    do: Map.get(payload, :output, Map.get(payload, :message, ""))

  defp compact_message("ToolCallFinished", payload) do
    tool = Map.get(payload, :tool_name, "tool")
    status = Map.get(payload, :status, "finished")
    "#{tool} #{status}"
  end

  defp compact_message(type, payload) do
    phase = Map.get(payload, :phase_id)
    status = Map.get(payload, :status)
    [type, phase, status] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  defp stream_name("WorkerStdout"), do: "stdout"
  defp stream_name("WorkerStderr"), do: "stderr"
  defp stream_name("AssistantMessage"), do: "assistant"
  defp stream_name("ToolCallFinished"), do: "tool"
  defp stream_name(_type), do: "event"

  defp collect_paths(events, key) do
    events
    |> Enum.flat_map(fn event -> List.wrap(Map.get(event.payload, key, [])) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp failure_entries(events) do
    events
    |> Enum.filter(
      &(&1.event_type in [
          "PhaseFailed",
          "PhaseTimedOut",
          "RunFailed",
          "MergeFailed",
          "MergeBlocked"
        ])
    )
    |> Enum.map(fn event ->
      %{
        event_id: event.event_id,
        type: event.event_type,
        phase_id: Map.get(event.payload, :phase_id),
        reason:
          Map.get(
            event.payload,
            :reason,
            Map.get(event.payload, :error, Map.get(event.payload, :details))
          ),
        occurred_at: event.occurred_at
      }
    end)
  end

  defp summary(run, events) do
    %{
      status: Map.get(run, :status, "unknown"),
      event_count: length(events),
      first_event: events |> List.first() |> event_type(),
      last_event: events |> List.last() |> event_type()
    }
  end

  defp event_type(nil), do: nil
  defp event_type(%Event{event_type: event_type}), do: event_type
end
