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

  alias ForemanServer.Aggregates.WorkRequest.State
  alias ForemanServer.Events.{WorkCancelled, WorkExecutionCompleted, WorkExecutionFailed, WorkSubmitted}

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
      :workflow_snapshot
    ]
  end

  @impl true
  def initial_state, do: %State{}

  @doc "Build the canonical stream id for a work request."
  @spec stream_id(String.t()) :: String.t()
  def stream_id(work_id), do: "work:#{work_id}"

  @impl true
  def handle_command(_state, _command), do: :unhandled

  @impl true
  def apply_event(%State{} = state, %WorkSubmitted{} = event) do
    %State{
      state
      | work_id: event.work_id,
        status: :submitted,
        project_id: event.project_id,
        run_id: event.run_id,
        submission_id: event.submission_id,
        workflow_snapshot: event.workflow_snapshot
    }
  end

  def apply_event(%State{} = state, %WorkCancelled{} = _event) do
    %State{state | status: :cancelled}
  end

  def apply_event(%State{} = state, %WorkExecutionCompleted{} = _event) do
    %State{state | status: :succeeded}
  end

  def apply_event(%State{} = state, %WorkExecutionFailed{} = _event) do
    %State{state | status: :failed}
  end
end
