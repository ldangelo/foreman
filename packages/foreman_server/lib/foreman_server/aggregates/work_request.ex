defmodule ForemanServer.Aggregates.WorkRequest do
  @moduledoc """
  Event-sourced aggregate for work request submissions.

  Stream id: `work:<work_id>`

  ## Status machine

      submitted → queued → running → succeeded | failed | cancelled

  The `queued` and `running` statuses are set by the Dispatcher on
  `WorkSubmitted` observation; `succeeded`, `failed`, and `cancelled`
  are terminal.
  """

  alias __MODULE__.State

  alias ForemanServer.Aggregate
  alias ForemanServer.Aggregates.WorkRequest.State
  alias ForemanServer.Commands.WorkSubmit
  alias ForemanServer.Identity
  alias ForemanServer.Telemetry

  alias ForemanServer.Events.{
    WorkCancelled,
    WorkExecutionCompleted,
    WorkExecutionFailed,
    WorkSubmitted
  }

  @behaviour ForemanServer.Aggregate

  defmodule State do
    @moduledoc "Work request aggregate state."
    @enforce_keys []
    defstruct [
      :work_id,
      :status,
      :project_id,
      :run_id,
      :bound_run_id,
      :submission_id,
      :workflow_snapshot,
      :submitted_at,
      :backend
    ]
  end

  @impl true
  def initial_state, do: %State{}

  @doc "Build the canonical stream id for a work request."
  @spec stream_id(String.t()) :: String.t()
  def stream_id(work_id), do: "work:#{work_id}"

  # Typed struct command: WorkSubmit
  @impl true
  def handle_command(state, %{__struct__: WorkSubmit} = cmd)
      when is_nil(state) or is_struct(state, State) do
    with {:ok, _} <- validate_prompt(cmd.prompt) do
      submission_id = cmd.submission_id || EventStore.UUID.uuid4()
      run_id = cmd.run_id || Identity.run_id(cmd.work_id, submission_id)

      # Emit work.submitted telemetry (TRD-042) — metadata whitelist: work_id, run_id,
      # workflow, project_id, prompt_bytes. Never include prompt body.
      workflow =
        Map.get(cmd.workflow_snapshot, "workflow") ||
          Map.get(cmd.workflow_snapshot, :workflow, "")

      prompt_bytes = byte_size(cmd.prompt)
      Telemetry.work_submitted(cmd.work_id, run_id, workflow, cmd.project_id, prompt_bytes)

      {:ok,
       %WorkSubmitted{
         work_id: cmd.work_id,
         project_id: cmd.project_id,
         workflow_snapshot: cmd.workflow_snapshot,
         submission_id: submission_id,
         run_id: run_id,
         backend: cmd.backend
       }}
    end
  end

  # Map-type work.submit — delegates to handle_submit_payload for both nil and State.
  def handle_command(nil, %{type: "work.submit", payload: payload})
      when is_map(payload) do
    handle_submit_payload(payload)
  end
  def handle_command(state, %{type: type, payload: payload})
      when is_struct(state, State) do
    case {type, state.status} do
      {"work.submit", nil} ->
        handle_submit_payload(payload)

      {"work.submit", :submitted} ->
        work_id = Map.get(payload, "work_id") || Map.get(payload, :work_id)
        if state.work_id == work_id, do: {:ok, nil}, else: {:error, {:already_submitted, state.work_id}}

      {"work.execution_complete", _} ->
        handle_execution_complete(state, payload)

      {"work.execution_fail", _} ->
        handle_execution_fail(state, payload)

      {"work.cancel", _} ->
        handle_cancel(state, payload)

      _ ->
        :unhandled
    end
  end

  # Unknown / unhandled commands (plain maps or nil state)
  def handle_command(_state, _command), do: :unhandled

  # ---------------------------------------------------------------------------
  # Private: command handlers
  # ---------------------------------------------------------------------------

  # Shared payload→WorkSubmitted logic for both nil and State map-type work.submit.
  defp handle_submit_payload(payload) do
    with {:ok, _} <- validate_prompt(Map.get(payload, "prompt") || Map.get(payload, :prompt)) do
      submission_id =
        Map.get(payload, "submission_id") || Map.get(payload, :submission_id) ||
          EventStore.UUID.uuid4()

      work_id = Map.get(payload, "work_id") || Map.get(payload, :work_id)
      run_id =
        Map.get(payload, "run_id") || Map.get(payload, :run_id) ||
          Identity.run_id(work_id, submission_id)

      project_id = Map.get(payload, "project_id") || Map.get(payload, :project_id)
      workflow_snapshot = Map.get(payload, "workflow_snapshot") || Map.get(payload, :workflow_snapshot)
      backend = Map.get(payload, "backend") || Map.get(payload, :backend)

      workflow =
        Map.get(workflow_snapshot, "workflow") ||
          Map.get(workflow_snapshot, :workflow, "")

      prompt_bytes =
        (Map.get(payload, "prompt") || Map.get(payload, :prompt))
        |> byte_size()

      Telemetry.work_submitted(work_id, run_id, workflow, project_id, prompt_bytes)

      {:ok,
       %WorkSubmitted{
         work_id: work_id,
         project_id: project_id,
         workflow_snapshot: workflow_snapshot,
         submission_id: submission_id,
         run_id: run_id,
         backend: backend
       }}
    end
  end

  defp handle_execution_complete(state, payload) do
    with {:ok, run_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :run_id, nil), :run_id),
         :ok <- require_run_matches_bound(state, run_id),
         :ok <- require_not_terminal(state) do
      work_id = Aggregate.get(payload, :work_id, nil)
      {:ok, %WorkExecutionCompleted{work_id: work_id, run_id: run_id}}
    end
  end

  defp handle_execution_fail(state, payload) do
    with {:ok, run_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :run_id, nil), :run_id),
         :ok <- require_run_matches_bound(state, run_id),
         :ok <- require_not_terminal(state) do
      work_id = Aggregate.get(payload, :work_id, nil)
      {:ok, %WorkExecutionFailed{work_id: work_id, run_id: run_id}}
    end
  end

  defp handle_cancel(%State{status: status}, _payload)
       when status in [:succeeded, :failed, :cancelled],
       do: {:ok, nil}

  defp handle_cancel(state, payload) do
    with :ok <- require_not_terminal(state) do
      work_id = Aggregate.get(payload, :work_id, nil)
      {:ok, %WorkCancelled{work_id: work_id}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private: validation helpers
  # ---------------------------------------------------------------------------

  defp validate_prompt(prompt) when is_binary(prompt) and byte_size(prompt) > 0, do: {:ok, prompt}
  defp validate_prompt(_), do: {:error, {:invalid_envelope, :missing_prompt}}

  defp require_not_terminal(%State{status: status})
       when status in [:succeeded, :failed, :cancelled],
       do: {:error, {:work_terminal, status}}

  defp require_not_terminal(%State{}), do: :ok

  # Compares payload run_id against bound_run_id in state.
  # Models Task.require_run_matches_bound/2.
  # Allows nil bound_run_id (work not yet bound to a run).
  defp require_run_matches_bound(%State{bound_run_id: nil}, _run_id), do: :ok

  defp require_run_matches_bound(%State{bound_run_id: bound}, run_id)
       when bound == run_id,
       do: :ok

  defp require_run_matches_bound(%State{bound_run_id: bound}, run_id),
    do: {:error, {:run_id_mismatch, bound, run_id}}

  @impl true
  def apply_event(%State{} = state, %ForemanServer.Events.WorkSubmitted{} = event) do
    %State{
      state
      | work_id: event.work_id,
        status: :submitted,
        project_id: event.project_id,
        run_id: event.run_id,
        submission_id: event.submission_id,
        workflow_snapshot: event.workflow_snapshot,
        submitted_at: System.monotonic_time(:microsecond),
        backend: event.backend
    }
  end

  def apply_event(%State{} = state, %ForemanServer.Events.WorkCancelled{} = _event) do
    duration_us =
      if state.submitted_at, do: System.monotonic_time(:microsecond) - state.submitted_at, else: 0

    run_id = state.run_id || ""
    Telemetry.work_terminal(state.work_id, run_id, :cancelled, duration_us)
    %State{state | status: :cancelled}
  end

  def apply_event(%State{} = state, %ForemanServer.Events.WorkExecutionCompleted{} = event) do
    duration_us =
      if state.submitted_at, do: System.monotonic_time(:microsecond) - state.submitted_at, else: 0

    Telemetry.work_terminal(event.work_id, event.run_id, :succeeded, duration_us)
    %State{state | status: :succeeded}
  end

  def apply_event(%State{} = state, %ForemanServer.Events.WorkExecutionFailed{} = event) do
    duration_us =
      if state.submitted_at, do: System.monotonic_time(:microsecond) - state.submitted_at, else: 0

    Telemetry.work_terminal(event.work_id, event.run_id, :failed, duration_us)
    %State{state | status: :failed}
  end

  def apply_event(%State{} = state, event) do
    payload = Aggregate.event_payload(event)
    type = Aggregate.event_type(event)

    case type do
      "work.submitted" ->
        apply_work_submitted(state, payload)

      "work.cancelled" ->
        apply_work_cancelled(state, payload)

      "work.execution_complete" ->
        apply_work_execution_complete(state, payload)

      "work.execution_fail" ->
        apply_work_execution_failed(state, payload)

      _ ->
        state
    end
  end

  # Called by apply_event/2 — kept private for use in tests (struct pattern matching).
  defp apply_work_submitted(%State{} = state, payload) do
    %State{
      state
      | work_id: Aggregate.get(payload, :work_id),
        status: :submitted,
        project_id: Aggregate.get(payload, :project_id),
        run_id: Aggregate.get(payload, :run_id),
        submission_id: Aggregate.get(payload, :submission_id),
        workflow_snapshot: Aggregate.get(payload, :workflow_snapshot),
        submitted_at: System.monotonic_time(:microsecond),
        backend: Aggregate.get(payload, :backend)
    }
  end

  defp apply_work_cancelled(%State{} = state, _payload) do
    duration_us =
      if state.submitted_at, do: System.monotonic_time(:microsecond) - state.submitted_at, else: 0

    run_id = state.run_id || ""
    Telemetry.work_terminal(state.work_id, run_id, :cancelled, duration_us)
    %State{state | status: :cancelled}
  end

  defp apply_work_execution_complete(%State{} = state, payload) do
    duration_us =
      if state.submitted_at, do: System.monotonic_time(:microsecond) - state.submitted_at, else: 0

    work_id = Aggregate.get(payload, :work_id)
    run_id = Aggregate.get(payload, :run_id)
    Telemetry.work_terminal(work_id, run_id, :succeeded, duration_us)
    %State{state | status: :succeeded}
  end

  defp apply_work_execution_failed(%State{} = state, payload) do
    duration_us =
      if state.submitted_at, do: System.monotonic_time(:microsecond) - state.submitted_at, else: 0

    work_id = Aggregate.get(payload, :work_id)
    run_id = Aggregate.get(payload, :run_id)
    Telemetry.work_terminal(work_id, run_id, :failed, duration_us)
    %State{state | status: :failed}
  end
end
