defmodule ForemanServer.Overwatch do
  @moduledoc """
  Backend-owned worker overwatch.

  Watches worker events to steer stale phases with Agent Mail and owns the
  synchronous tool policy gate workers call before executing tools.

  Phase transitions are dynamic based on the workflow's phase_order (from RunStarted),
  not hardcoded phase names.
  """

  use GenServer

  alias ForemanServer.{Event, EventStore, Inbox}

  @stale_intervals 2
  @max_nudges 3

  @type decision :: %{
          allowed: boolean(),
          action: String.t(),
          reason: String.t(),
          message: String.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{phases: %{}, steering: %{}, run_phase_orders: %{}}}

  @spec handle_event(Event.t()) :: :ok
  def handle_event(%Event{} = event) do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:event, event})
    :ok
  end

  @impl true
  def handle_cast({:event, %Event{} = event}, state) do
    {:noreply, observe_event(event, state)}
  end

  @spec check_tool(map()) :: {:ok, decision()} | {:error, term()}
  def check_tool(input) when is_map(input) do
    run_id = fetch(input, :run_id)
    phase_id = fetch(input, :phase_id) || fetch(input, :phase) || "unknown"
    tool_name = normalize_tool(fetch(input, :tool_name) || fetch(input, :toolName))
    args = fetch(input, :args) || %{}

    with {:ok, run_id} <- required_binary(run_id, :run_id),
         {:ok, tool_name} <- required_binary(tool_name, :tool_name),
         :ok <- append_requested(input, run_id, phase_id, tool_name, args) do
      decision = decide_tool(phase_id, tool_name, args)
      append_decision(input, run_id, phase_id, tool_name, args, decision)
      maybe_send_tool_nudge(run_id, phase_id, tool_name, decision)
      {:ok, decision}
    end
  end

  # Track phase_order from RunStarted events for dynamic phase transitions
  defp observe_event(%Event{event_type: "RunStarted", payload: payload}, state) do
    run_id = fetch(payload, :run_id)
    phase_order = fetch(payload, :phase_order) || []

    if is_binary(run_id) and is_list(phase_order) do
      update_in(state.run_phase_orders, &Map.put(&1, run_id, phase_order))
    else
      state
    end
  end

  defp observe_event(%Event{event_type: "PhaseStarted", payload: payload}, state) do
    key = phase_key(payload)
    put_phase(state, key, fresh_phase(payload))
  end

  defp observe_event(%Event{event_type: "PhaseReportProduced", payload: payload}, state) do
    maybe_send_report_steering(state, payload)
  end

  defp observe_event(%Event{event_type: "PhaseCompleted", payload: payload}, state) do
    update_in(state.phases, &Map.delete(&1, phase_key(payload)))
  end

  defp observe_event(%Event{event_type: "PhaseRetried"}, state), do: state

  defp observe_event(%Event{event_type: "PhaseFailed", payload: payload}, state) do
    update_in(state.phases, &Map.delete(&1, phase_key(payload)))
  end

  # Clean up run data when run terminates
  defp observe_event(%Event{event_type: terminal, payload: payload}, state)
       when terminal in ["RunCompleted", "RunFailed"] do
    run_id = fetch(payload, :run_id)
    key = phase_key(payload)

    state
    |> update_in([:phases], &Map.delete(&1, key))
    |> update_in([:run_phase_orders], &Map.delete(&1, run_id))
  end

  defp observe_event(%Event{event_type: "WorkerHeartbeat", payload: payload}, state) do
    key = phase_key(payload)
    phase = Map.get(state.phases, key, fresh_phase(payload))
    signature = activity_signature(phase)

    cond do
      phase.last_signature in [nil, signature] and phase.last_signature != nil ->
        stale_count = phase.stale_count + 1
        phase = %{phase | stale_count: stale_count}

        if stale_count >= @stale_intervals and phase.nudge_count < @max_nudges do
          nudge_count = phase.nudge_count + 1

          reason =
            "No new assistant/tool activity for #{@stale_intervals} heartbeat intervals. Summarize current state, choose the next concrete action, and avoid repeating failed tool calls."

          send_overwatch_nudge(
            phase.run_id,
            phase.phase_id,
            "overwatch nudge: stale phase",
            reason
          )

          append_phase_nudge(phase.run_id, phase.phase_id, reason, nudge_count)

          put_phase(state, key, %{
            phase
            | stale_count: 0,
              nudge_count: nudge_count,
              last_signature: signature
          })
        else
          put_phase(state, key, phase)
        end

      true ->
        put_phase(state, key, %{phase | stale_count: 0, last_signature: signature})
    end
  end

  defp observe_event(%Event{event_type: event_type, payload: payload}, state)
       when event_type in [
              "AssistantMessage",
              "ToolCallFinished",
              "ToolCallRequested",
              "ToolCallApproved",
              "ToolCallDenied"
            ] do
    key = phase_key(payload)
    phase = Map.get(state.phases, key, fresh_phase(payload))

    phase =
      case event_type do
        "AssistantMessage" ->
          %{phase | assistant_count: phase.assistant_count + 1, stale_count: 0}

        "ToolCallFinished" ->
          %{phase | tool_count: phase.tool_count + 1, stale_count: 0}

        "ToolCallDenied" ->
          %{phase | denied_count: phase.denied_count + 1, stale_count: 0}

        _ ->
          phase
      end

    put_phase(state, key, phase)
  end

  defp observe_event(_event, state), do: state

  defp fresh_phase(payload) do
    %{
      run_id: fetch(payload, :run_id),
      phase_id: fetch(payload, :phase_id) || fetch(payload, :phase) || "pipeline",
      assistant_count: 0,
      tool_count: 0,
      denied_count: 0,
      stale_count: 0,
      nudge_count: 0,
      last_signature: nil
    }
  end

  defp phase_key(payload),
    do:
      {fetch(payload, :run_id), fetch(payload, :phase_id) || fetch(payload, :phase) || "pipeline"}

  defp put_phase(state, key, phase), do: put_in(state.phases[key], phase)

  defp activity_signature(phase),
    do: {phase.assistant_count, phase.tool_count, phase.denied_count}

  defp maybe_send_report_steering(state, payload) do
    report_payload = report_payload(payload)

    with {:ok, run_id} <- required_binary(fetch(report_payload, :run_id), :run_id),
         {:ok, phase_id} <-
           required_binary(
             fetch(report_payload, :phase_id) || fetch(report_payload, :phase),
             :phase_id
           ),
         target when is_binary(target) <- steering_target(state, report_payload, run_id, phase_id) do
      outcome = fetch(report_payload, :outcome) || fetch(report_payload, :status) || "completed"
      key = {run_id, phase_id, target, outcome}
      count = Map.get(state.steering, key, 0) + 1

      send_report_steering(
        run_id,
        fetch(report_payload, :task_id),
        phase_id,
        target,
        outcome,
        report_payload,
        count
      )

      put_in(state.steering[key], count)
    else
      _ -> state
    end
  end

  defp report_payload(payload) do
    details = fetch(payload, :details)
    if is_map(details), do: Map.merge(details, payload), else: payload
  end

  # Dynamic steering target based on workflow phase_order and explicit payload values
  defp steering_target(state, payload, run_id, phase_id) do
    retry_target = fetch(payload, :retryTarget) || fetch(payload, :retry_target)
    next_phase = fetch(payload, :nextPhase) || fetch(payload, :next_phase)
    outcome = fetch(payload, :outcome) || fetch(payload, :status)

    cond do
      # Explicit retry target from payload takes precedence
      is_binary(retry_target) and retry_target != "" ->
        retry_target

      # Explicit next phase from payload takes precedence
      is_binary(next_phase) and next_phase != "" ->
        next_phase

      # For retry outcome, try to find a retry target in workflow or use generic fallback
      outcome == "retry" ->
        find_retry_target(state, run_id, phase_id)

      # For pass/complete, use workflow's next phase
      true ->
        find_next_phase(state, run_id, phase_id)
    end
  end

  # Find the next phase dynamically from the workflow's phase_order
  defp find_next_phase(state, run_id, phase_id) do
    phase_order = Map.get(state.run_phase_orders, run_id, [])

    case Enum.find_index(phase_order, &(&1 == phase_id)) do
      nil ->
        # Phase not found in order, try generic fallback
        nil

      index when index + 1 < length(phase_order) ->
        Enum.at(phase_order, index + 1)

      _ ->
        # This is the last phase
        nil
    end
  end

  # Find retry target: look for a non-retryOnly phase before current or use generic fallback
  defp find_retry_target(state, run_id, phase_id) do
    phase_order = Map.get(state.run_phase_orders, run_id, [])

    current_index = Enum.find_index(phase_order, &(&1 == phase_id))

    if is_nil(current_index) do
      # Generic fallback: retry typically goes to development phase
      generic_retry_target(phase_id)
    else
      # Find previous non-retryOnly phase (for now, just return previous phase if exists)
      # In the future, this could check phase metadata for retryOnly flag
      if current_index > 0 do
        Enum.at(phase_order, current_index - 1)
      else
        generic_retry_target(phase_id)
      end
    end
  end

  # Generic retry target based on phase name patterns (fallback when workflow not available)
  defp generic_retry_target(phase_id) do
    cond do
      String.contains?(phase_id, "qa") -> "developer"
      String.contains?(phase_id, "review") -> "developer"
      String.contains?(phase_id, "finalize") -> "developer"
      String.contains?(phase_id, "documentation") -> "developer"
      true -> nil
    end
  end

  defp send_report_steering(run_id, task_id, phase_id, target, outcome, payload, loop_count) do
    summary = fetch(payload, :summary) || %{}

    source_report =
      source_report_name(fetch(payload, :artifacts)) || fetch(payload, :sourceReport) ||
        fetch(payload, :source_report)

    body =
      Jason.encode!(%{
        kind: "steering",
        source: "overwatch",
        taskId: task_id,
        runId: run_id,
        phase: phase_id,
        targetPhase: target,
        outcome: outcome,
        sourceReport: source_report,
        reportId: fetch(payload, :report_id) || fetch(payload, :reportId),
        loopCount: loop_count,
        summary: summary,
        instructions: steering_instructions(phase_id, target, outcome)
      })

    Inbox.send_operator_message(%{
      run_id: run_id,
      phase_id: target,
      from: "overwatch",
      to: target,
      subject: "overwatch steering: #{phase_id} → #{target}",
      body: body,
      worker_supports_receiving: true
    })
  end

  defp source_report_name([first | _]) when is_map(first), do: fetch(first, :name)
  defp source_report_name(_), do: nil

  # Generic steering instructions - not tied to specific phase names
  # Phase-specific behavior should be defined in workflow YAML, not here
  defp steering_instructions(phase_id, target, outcome) do
    cond do
      # QA verification phase: retry outcome should reference QA failure evidence
      String.contains?(phase_id, "qa") and outcome == "retry" ->
        "Use QA failure evidence only. Patch the smallest target, avoid broad rewrites, then update the relevant report for the next pass."

      String.contains?(phase_id, "qa") ->
        "Use the prior phase report as handoff. Run focused verification and write QA_REPORT.md with concrete command evidence."

      # Documentation phase instructions apply when targeting documentation phase
      String.contains?(target, "documentation") ->
        "Use the source report and current diff to verify documentation coverage. For documentation-focused tasks with existing doc edits, report instead of broadening scope unless acceptance criteria are clearly missing. Do not run tests."

      # Default generic instructions
      true ->
        "Use the source report as steering context. Avoid rediscovery unless the report conflicts with direct evidence."
    end
  end

  defp decide_tool(_phase_id, "read", args) do
    path = fetch(args, :path) || fetch(args, :file_path) || fetch(args, :filePath)

    cond do
      not is_binary(path) or path == "" ->
        deny("read requires explicit file path")

      File.dir?(path) ->
        deny("read target is a directory; use Glob to select regular files")

      missing_read_path?(path) ->
        deny("read target does not exist; rediscover with Grep or Glob")

      true ->
        approve("tool allowed")
    end
  end

  defp decide_tool(_phase_id, tool_name, _args)
       when tool_name in ["graphify", "graphifyquery", "graphifyexplain"] do
    deny("Graphify tools are disabled; use Grep, Glob, and Read")
  end

  # Removed hardcoded explorer phase restrictions.
  # Tool restrictions should be defined in workflow YAML (tools.allowed),
  # not hardcoded in the backend.

  defp decide_tool(_phase_id, "bash", args) do
    command = fetch(args, :command) || ""

    if dangerous_command?(command) do
      deny("destructive Foreman/server process-control commands are blocked in workers")
    else
      approve("tool allowed")
    end
  end

  defp decide_tool(_phase_id, _tool_name, _args), do: approve("tool allowed")

  defp approve(reason), do: %{allowed: true, action: "approve", reason: reason, message: nil}
  defp deny(reason), do: %{allowed: false, action: "deny", reason: reason, message: reason}

  defp missing_read_path?(path), do: Path.type(path) == :absolute and not File.exists?(path)

  defp dangerous_command?(command) when is_binary(command) do
    normalized = command |> String.downcase() |> String.replace(~r/\s+/, " ")

    Regex.match?(~r/\b(kill|pkill|killall)\b/, normalized) or
      Regex.match?(~r/\bxargs\s+kill\b/, normalized) or
      Regex.match?(~r/\bfuser\b.*\s-k\b/, normalized) or
      Regex.match?(~r/\blsof\s+[^;&|]*-ti:?4766\b/, normalized) or
      Regex.match?(~r/\bforeman\s+server\s+(stop|restart)\b/, normalized)
  end

  defp dangerous_command?(_), do: false

  defp append_requested(input, run_id, phase_id, tool_name, args) do
    EventStore.append(%{
      stream_id: "run:#{run_id}",
      event_type: "ToolCallRequested",
      payload: base_payload(input, run_id, phase_id, tool_name, args),
      metadata: %{correlation_id: run_id}
    })
    |> case do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_decision(input, run_id, phase_id, tool_name, args, decision) do
    event_type = if decision.allowed, do: "ToolCallApproved", else: "ToolCallDenied"

    EventStore.append(%{
      stream_id: "run:#{run_id}",
      event_type: event_type,
      payload:
        base_payload(input, run_id, phase_id, tool_name, args)
        |> Map.put(:allowed, decision.allowed)
        |> Map.put(:action, decision.action)
        |> Map.put(:reason, decision.reason)
        |> Map.put(:message, decision.message),
      metadata: %{correlation_id: run_id}
    })
  end

  defp append_phase_nudge(run_id, phase_id, reason, nudge_count) do
    EventStore.append(%{
      stream_id: "run:#{run_id}",
      event_type: "PhaseNudged",
      payload: %{
        run_id: run_id,
        phase_id: phase_id,
        message: reason,
        nudge_count: nudge_count,
        source: "elixir_overwatch"
      },
      metadata: %{correlation_id: run_id}
    })
  end

  defp maybe_send_tool_nudge(run_id, phase_id, tool_name, %{allowed: false, reason: reason}) do
    send_overwatch_nudge(
      run_id,
      phase_id,
      "overwatch tool denied: #{tool_name}",
      "Tool #{tool_name} denied: #{reason}. Adjust approach and continue with allowed discovery/workflow tools."
    )
  end

  defp maybe_send_tool_nudge(_run_id, _phase_id, _tool_name, _decision), do: :ok

  defp send_overwatch_nudge(run_id, phase_id, subject, body) do
    Inbox.send_operator_message(%{
      run_id: run_id,
      phase_id: phase_id,
      from: "overwatch",
      to: phase_id,
      subject: subject,
      body: body,
      worker_supports_receiving: true
    })
  end

  defp base_payload(input, run_id, phase_id, tool_name, args) do
    %{
      run_id: run_id,
      task_id: fetch(input, :task_id),
      phase_id: phase_id,
      worker_id: fetch(input, :worker_id),
      sequence: fetch(input, :sequence),
      tool_call_id: fetch(input, :tool_call_id) || fetch(input, :toolCallId),
      tool_name: tool_name,
      args: args
    }
  end

  defp normalize_tool(tool) when is_binary(tool), do: String.downcase(tool)
  defp normalize_tool(tool), do: tool

  defp fetch(map, key) when is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp required_binary(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  defp required_binary(_value, key), do: {:error, {:missing_or_invalid, key}}
end
