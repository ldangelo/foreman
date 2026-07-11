defmodule ForemanServer.DebugViews do
  @moduledoc "Event-backed log, report, and debug timeline read views."

  alias ForemanServer.{Event, EventStore, ProjectionStore}

  @max_string_length 4_096
  @redacted "[REDACTED]"
  @truncated_suffix "...[truncated]"
  @secret_key_names MapSet.new(~w(
    access_token api_key apikey authorization auth_token client_secret password secret token
  ))

  @secret_key_pattern @secret_key_names
                      |> MapSet.to_list()
                      |> Enum.flat_map(fn key ->
                        key
                        |> String.replace("_", "-")
                        |> then(&[key, &1])
                      end)
                      |> Enum.uniq()
                      |> Enum.sort_by(&byte_size/1, :desc)
                      |> Enum.map(&Regex.escape/1)
                      |> Enum.join("|")

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
       anomalies: timeline_anomalies(timeline),
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
      payload: sanitize_value(event.payload),
      metadata: sanitize_value(event.metadata)
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
      message: compact_message(event.event_type, payload) |> sanitize_string(),
      occurred_at: event.occurred_at
    }
  end

  defp timeline_entry(%Event{} = event) do
    payload = event.payload
    file_changes = file_changes_from_payload(payload)

    %{
      event_id: event.event_id,
      sequence: event.stream_version,
      type: event.event_type,
      phase_id: Map.get(payload, :phase_id),
      worker_id: Map.get(payload, :worker_id),
      status: Map.get(payload, :status),
      artifact_paths: Map.get(payload, :artifact_paths, []) |> sanitize_value(),
      report_paths: Map.get(payload, :report_paths, []) |> sanitize_value(),
      reason: Map.get(payload, :reason, Map.get(payload, :error)) |> sanitize_value(),
      payload: payload |> debug_payload() |> sanitize_value(),
      file_changes: file_changes |> sanitize_value(),
      occurred_at: event.occurred_at
    }
    |> drop_empty(:file_changes)
  end

  defp debug_payload(payload) do
    payload
    |> Map.take([
      :action,
      :args,
      :details,
      :error,
      :files,
      :files_changed,
      :filesChanged,
      :output,
      :path,
      :phase_id,
      :reason,
      :status,
      :tool_name,
      :worker_id
    ])
  end

  defp drop_empty(map, key) do
    case Map.get(map, key) do
      nil -> Map.delete(map, key)
      [] -> Map.delete(map, key)
      _ -> map
    end
  end

  defp file_changes_from_payload(payload) when is_map(payload) do
    [
      nested_payload(payload, [:output, :changed]),
      nested_payload(payload, [:output, :files_changed]),
      nested_payload(payload, [:output, :filesChanged]),
      nested_payload(payload, [:output, :files]),
      Map.get(payload, :changed),
      Map.get(payload, :files_changed),
      Map.get(payload, :filesChanged),
      Map.get(payload, :files),
      nested_payload(payload, [:details, :changed]),
      nested_payload(payload, [:details, :files_changed]),
      nested_payload(payload, [:details, :filesChanged]),
      nested_payload(payload, [:details, :files])
    ]
    |> Enum.find_value(&normalize_file_changes/1)
    |> Kernel.||([])
  end

  defp file_changes_from_payload(_payload), do: []

  defp nested_payload(map, [key | rest]) when is_map(map) do
    nested_payload(Map.get(map, key), rest)
  end

  defp nested_payload(value, []), do: value
  defp nested_payload(_value, _path), do: nil

  defp normalize_file_changes(changes) when is_list(changes) do
    changes
    |> Enum.map(&normalize_file_change/1)
    |> Enum.reject(&is_nil/1)
    |> then(fn
      [] -> nil
      normalized -> normalized
    end)
  end

  defp normalize_file_changes(_changes), do: nil

  defp normalize_file_change(path) when is_binary(path) and path != "" do
    %{path: path, change: "M"}
  end

  defp normalize_file_change(%{} = change) do
    path =
      Map.get(change, :path) || Map.get(change, "path") || Map.get(change, :file) ||
        Map.get(change, "file")

    if is_binary(path) and path != "" do
      %{
        path: path,
        change:
          Map.get(change, :change) || Map.get(change, "change") || Map.get(change, :status) ||
            Map.get(change, "status") || "M",
        additions: Map.get(change, :additions) || Map.get(change, "additions"),
        deletions: Map.get(change, :deletions) || Map.get(change, "deletions"),
        conflict: Map.get(change, :conflict) || Map.get(change, "conflict") || false
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end
  end

  defp normalize_file_change(_change), do: nil

  defp timeline_anomalies(timeline) do
    {_state, anomalies} =
      Enum.reduce(timeline, {%{run_started: false, terminal: false, phases: %{}}, []}, fn entry,
                                                                                          {state,
                                                                                           anomalies} ->
        {state, anomaly} = apply_timeline_entry(state, entry)
        anomalies = if anomaly, do: anomalies ++ [anomaly], else: anomalies
        {state, anomalies}
      end)

    %{
      first: List.first(anomalies),
      entries: anomalies,
      count: length(anomalies)
    }
  end

  defp apply_timeline_entry(state, %{type: "RunStarted"}),
    do: {%{state | run_started: true}, nil}

  defp apply_timeline_entry(state, %{type: type} = entry)
       when type in ["RunCompleted", "RunFailed", "RunBlocked"] do
    anomaly =
      cond do
        not state.run_started -> anomaly(entry, "run_terminal_before_start")
        state.terminal -> anomaly(entry, "duplicate_terminal_run_transition")
        true -> nil
      end

    {%{state | terminal: true}, anomaly}
  end

  defp apply_timeline_entry(state, %{type: "PhaseStarted", phase_id: phase_id} = entry) do
    anomaly = if state.terminal, do: anomaly(entry, "phase_started_after_terminal_run")

    state = put_in(state, [:phases, phase_id], "started")
    {state, anomaly}
  end

  defp apply_timeline_entry(state, %{type: type, phase_id: phase_id} = entry)
       when type in ["PhaseCompleted", "PhaseFailed", "PhaseTimedOut"] do
    phase_state = Map.get(state.phases, phase_id)

    anomaly =
      cond do
        not state.run_started -> anomaly(entry, "phase_terminal_before_run_start")
        state.terminal -> anomaly(entry, "phase_terminal_after_run_terminal")
        phase_state != "started" -> anomaly(entry, "phase_terminal_before_phase_start")
        true -> nil
      end

    state = put_in(state, [:phases, phase_id], "terminal")
    {state, anomaly}
  end

  defp apply_timeline_entry(state, entry) do
    anomaly = if state.terminal, do: anomaly(entry, "event_after_terminal_run")
    {state, anomaly}
  end

  defp anomaly(entry, reason) do
    %{
      event_id: entry.event_id,
      sequence: entry.sequence,
      type: entry.type,
      phase_id: Map.get(entry, :phase_id),
      reason: reason,
      occurred_at: entry.occurred_at
    }
  end

  defp compact_message("WorkerStdout", payload), do: Map.get(payload, :output, "")
  defp compact_message("WorkerStderr", payload), do: Map.get(payload, :output, "")

  defp compact_message("AssistantMessage", payload),
    do: Map.get(payload, :output) || Map.get(payload, :message, "")

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
    |> Enum.map(&sanitize_value/1)
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
          )
          |> sanitize_value(),
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

  defp sanitize_value(%DateTime{} = value), do: value
  defp sanitize_value(%NaiveDateTime{} = value), do: value

  defp sanitize_value(value) when is_map(value) do
    Map.new(value, fn {key, item} ->
      if secret_key?(key), do: {key, @redacted}, else: {key, sanitize_value(item)}
    end)
  end

  defp sanitize_value(value) when is_list(value), do: Enum.map(value, &sanitize_value/1)
  defp sanitize_value(value) when is_binary(value), do: sanitize_string(value)
  defp sanitize_value(value), do: value

  defp sanitize_string(value) do
    value
    |> redact_secret_patterns()
    |> truncate_string()
  end

  defp redact_secret_patterns(value) do
    value =
      Regex.replace(
        ~r/\b(authorization)\s*[:=]\s*(?:bearer\s+)?[^\s,&;]+/i,
        value,
        fn _match, key -> "#{key}: #{@redacted}" end
      )

    value = Regex.replace(~r/\bbearer\s+[^\s,&;]+/i, value, "Bearer #{@redacted}")

    Regex.replace(
      ~r/(^|[^\w])(["']?)(#{@secret_key_pattern})\2\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,&;}]+)/i,
      value,
      fn _match, prefix, quote, key -> "#{prefix}#{quote}#{key}#{quote}=#{@redacted}" end
    )
  end

  defp truncate_string(value) when byte_size(value) <= @max_string_length, do: value

  defp truncate_string(value) do
    keep = max(@max_string_length - byte_size(@truncated_suffix), 0)

    value
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {acc, size} ->
      next_size = size + byte_size(grapheme)

      if next_size > keep do
        {:halt, {acc, size}}
      else
        {:cont, {[grapheme | acc], next_size}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
    |> Kernel.<>(@truncated_suffix)
  end

  defp secret_key?(key) do
    key
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "_")
    |> then(&MapSet.member?(@secret_key_names, &1))
  end
end
