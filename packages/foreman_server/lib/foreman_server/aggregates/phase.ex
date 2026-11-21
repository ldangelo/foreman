defmodule ForemanServer.Aggregates.Phase do
  @moduledoc "Phase aggregate: validates per-run phase state transitions."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  defmodule State do
    @enforce_keys [:exists?, :phase_id, :run_id, :status, :terminal?]
    defstruct [:exists?, :phase_id, :run_id, :status, :terminal?, attempt: 0]
  end

  @impl true
  def initial_state,
    do: %State{
      exists?: false,
      phase_id: nil,
      run_id: nil,
      status: nil,
      terminal?: false,
      attempt: 0
    }

  @impl true
  def apply_event(%State{} = state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "PhaseStarted" ->
        %State{
          state
          | exists?: true,
            phase_id: Aggregate.get(payload, :phase_id),
            run_id: Aggregate.get(payload, :run_id),
            status: "in_progress",
            terminal?: false,
            attempt: Aggregate.get(payload, :attempt, state.attempt)
        }

      "PhaseCompleted" ->
        %State{state | status: "completed", terminal?: true}

      "PhaseFailed" ->
        %State{state | status: "failed", terminal?: true}

      "PhaseTimedOut" ->
        %State{state | status: "timed_out", terminal?: true}

      "PhaseBlocked" ->
        %State{state | status: "blocked", terminal?: true}

      "PhaseRetried" ->
        resumed? = Aggregate.get(payload, :reason) == "resumed"

        %State{
          state
          | phase_id: Aggregate.get(payload, :phase_id),
            run_id: Aggregate.get(payload, :run_id),
            attempt: Aggregate.get(payload, :attempt, state.attempt + 1),
            status: if(resumed?, do: "in_progress", else: "retrying"),
            terminal?: false
        }

      "PhaseSkipped" ->
        %State{state | status: "skipped", terminal?: true}

      _ ->
        state
    end
  end

  @impl true
  def handle_command(state, %{type: "phase.start", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, phase_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :phase_id), :phase_id),
         :ok <- require_absent(state),
         :ok <- reject_terminal(state) do
      {:ok,
       %{
         stream_id: "phase:#{run_id}:#{phase_id}",
         event_type: "PhaseStarted",
         payload: Map.merge(payload, %{run_id: run_id, phase_id: phase_id})
       }}
    end
  end

  # The project context a launch delivered. Only a started, non-terminal phase
  # records one, and every field is checked here: the event is decoded strictly
  # and the projection folds it, so a malformed payload must never reach the stream
  # (AGENTS.md 5.3). `sha256` is the hash of the project-context `system_text` only,
  # not of later additions to the system prompt (operator progress addendum,
  # steering); "recorded" means the launch built the context, not that the agent started.
  def handle_command(state, %{type: "phase.context", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, phase_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :phase_id), :phase_id),
         :ok <- require_started(state, "phase.context"),
         :ok <- reject_terminal(state),
         {:ok, sha256} <- Aggregate.required_binary(Aggregate.get(payload, :sha256), :sha256),
         {:ok, bytes} <- non_neg_integer(Aggregate.get(payload, :bytes), :bytes),
         {:ok, redactions} <- non_neg_integer(Aggregate.get(payload, :redactions), :redactions),
         {:ok, sections} <- sections(Aggregate.get(payload, :sections)),
         {:ok, truncated} <- truncations(Aggregate.get(payload, :truncated)),
         :ok <- redaction_scope(Aggregate.get(payload, :redaction_scope)) do
      {:ok,
       %{
         stream_id: "phase:#{run_id}:#{phase_id}",
         event_type: "PhaseContextRecorded",
         payload: %{
           run_id: run_id,
           phase_id: phase_id,
           sections: sections,
           sha256: sha256,
           bytes: bytes,
           truncated: truncated,
           redactions: redactions,
           redaction_scope: "project_context_sections"
         }
       }}
    end
  end

  def handle_command(state, %{type: type, payload: payload})
      when type in [
             "phase.complete",
             "phase.fail",
             "phase.timeout",
             "phase.retry",
             "phase.skip",
             "phase.block"
           ] do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, phase_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :phase_id), :phase_id),
         :ok <- require_started(state, type),
         :ok <- reject_terminal_for_non_retry(state, type, payload) do
      event_type =
        %{
          "phase.complete" => "PhaseCompleted",
          "phase.fail" => "PhaseFailed",
          "phase.timeout" => "PhaseTimedOut",
          "phase.retry" => "PhaseRetried",
          "phase.skip" => "PhaseSkipped",
          "phase.block" => "PhaseBlocked"
        }[type]

      {:ok,
       %{
         stream_id: "phase:#{run_id}:#{phase_id}",
         event_type: event_type,
         payload:
           type
           |> event_payload(payload, run_id, phase_id)
           |> stamp_attempt(type, state)
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp require_absent(%State{exists?: true}), do: {:error, :phase_already_started}
  defp require_absent(_state), do: :ok

  defp require_started(%State{exists?: true}, _type), do: :ok
  defp require_started(_state, _type), do: {:error, :phase_not_started}

  defp reject_terminal(%State{terminal?: true}), do: {:error, :phase_terminal}
  defp reject_terminal(_state), do: :ok

  defp non_neg_integer(value, _key) when is_integer(value) and value >= 0, do: {:ok, value}
  defp non_neg_integer(_value, key), do: {:error, {:missing_or_invalid, key}}

  defp redaction_scope("project_context_sections"), do: :ok
  defp redaction_scope(_other), do: {:error, {:missing_or_invalid, :redaction_scope}}

  defp sections(entries) when is_list(entries) do
    collect(entries, :sections, fn entry ->
      with {:ok, id} <- Aggregate.required_binary(Aggregate.get(entry, :id), :sections),
           {:ok, bytes} <- non_neg_integer(Aggregate.get(entry, :bytes), :sections) do
        {:ok, %{id: id, bytes: bytes}}
      end
    end)
  end

  defp sections(_other), do: {:error, {:missing_or_invalid, :sections}}

  defp truncations(entries) when is_list(entries) do
    collect(entries, :truncated, fn entry ->
      with {:ok, section} <- Aggregate.required_binary(Aggregate.get(entry, :section), :truncated),
           {:ok, omitted_bytes} <-
             non_neg_integer(Aggregate.get(entry, :omitted_bytes), :truncated),
           {:ok, omitted_lines} <-
             non_neg_integer(Aggregate.get(entry, :omitted_lines), :truncated) do
        {:ok, %{section: section, omitted_bytes: omitted_bytes, omitted_lines: omitted_lines}}
      end
    end)
  end

  defp truncations(_other), do: {:error, {:missing_or_invalid, :truncated}}

  # Maps `fun` over a list of maps; the first malformed entry fails the whole list.
  defp collect(entries, key, fun) do
    entries
    |> Enum.reduce_while({:ok, []}, fn
      %{} = entry, {:ok, acc} ->
        case fun.(entry) do
          {:ok, value} -> {:cont, {:ok, [value | acc]}}
          {:error, _} -> {:halt, {:error, {:missing_or_invalid, key}}}
        end

      _other, _acc ->
        {:halt, {:error, {:missing_or_invalid, key}}}
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  # `PhaseRetried` is decoded strictly, so only its declared fields reach the
  # stream (AGENTS.md 5.4b); an absent optional field stays absent.
  defp event_payload("phase.retry", payload, run_id, phase_id) do
    for key <- [:index, :reason, :prior_worktree_discarded, :input_artifacts],
        value = Aggregate.get(payload, key),
        value != nil,
        into: %{run_id: run_id, phase_id: phase_id},
        do: {key, value}
  end

  defp event_payload(_type, payload, run_id, phase_id),
    do: Map.merge(payload, %{run_id: run_id, phase_id: phase_id})

  # The attempt comes from the stream, never from the caller.
  defp stamp_attempt(payload, "phase.retry", %State{attempt: attempt}),
    do: Map.put(payload, :attempt, attempt + 1)

  defp stamp_attempt(payload, _type, _state), do: payload

  defp reject_terminal_for_non_retry(%State{status: "in_progress"}, "phase.retry", payload) do
    if Aggregate.get(payload, :reason) == "resumed",
      do: :ok,
      else: {:error, :phase_not_retryable}
  end

  # `resumed` is the restart of an in_progress phase; a failed, timed-out or
  # retrying phase takes an ordinary retry only.
  defp reject_terminal_for_non_retry(%State{status: status}, "phase.retry", payload)
       when status in ["failed", "timed_out", "retrying"] do
    if Aggregate.get(payload, :reason) == "resumed",
      do: {:error, :phase_not_retryable},
      else: :ok
  end

  defp reject_terminal_for_non_retry(%State{}, "phase.retry", _payload),
    do: {:error, :phase_not_retryable}

  defp reject_terminal_for_non_retry(state, _type, _payload), do: reject_terminal(state)
end
