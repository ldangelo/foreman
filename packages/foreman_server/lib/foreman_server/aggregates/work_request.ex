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
      :submitted_at
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
         run_id: run_id
       }}
    end
  end

  # Map-type commands — only for State structs (not plain maps)
  def handle_command(state, %{type: type, payload: payload})
      when is_struct(state, State) do
    case type do
      "work.execution_complete" ->
        handle_execution_complete(state, payload)

      "work.execution_fail" ->
        handle_execution_fail(state, payload)

      "work.cancel" ->
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
  def apply_event(%State{} = state, %WorkSubmitted{} = event) do
    %State{
      state
      | work_id: event.work_id,
        status: :submitted,
        project_id: event.project_id,
        run_id: event.run_id,
        submission_id: event.submission_id,
        workflow_snapshot: event.workflow_snapshot,
        submitted_at: System.monotonic_time(:microsecond)
    }
  end

  def apply_event(%State{} = state, %WorkCancelled{} = event) do
    duration_us =
      if state.submitted_at, do: System.monotonic_time(:microsecond) - state.submitted_at, else: 0

    run_id = state.run_id || ""
    Telemetry.work_terminal(event.work_id, run_id, :cancelled, duration_us)
    %State{state | status: :cancelled}
  end

  def apply_event(%State{} = state, %WorkExecutionCompleted{} = event) do
    duration_us =
      if state.submitted_at, do: System.monotonic_time(:microsecond) - state.submitted_at, else: 0

    Telemetry.work_terminal(event.work_id, event.run_id, :succeeded, duration_us)
    %State{state | status: :succeeded}
  end

  def apply_event(%State{} = state, %WorkExecutionFailed{} = event) do
    duration_us =
      if state.submitted_at, do: System.monotonic_time(:microsecond) - state.submitted_at, else: 0

    Telemetry.work_terminal(event.work_id, event.run_id, :failed, duration_us)
    %State{state | status: :failed}
  end
end
