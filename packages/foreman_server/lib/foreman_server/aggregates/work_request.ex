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
  alias ForemanServer.Commands.WorkSubmit
  alias ForemanServer.Identity
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
  def handle_command(state, %{__struct__: WorkSubmit} = cmd)
      when is_nil(state) or is_struct(state, State) do
    with {:ok, _} <- validate_prompt(cmd.prompt) do
      submission_id = cmd.submission_id || EventStore.UUID.uuid4()
      run_id = cmd.run_id || Identity.run_id(cmd.work_id, submission_id)

      {:ok, %WorkSubmitted{
        work_id: cmd.work_id,
        project_id: cmd.project_id,
        workflow_snapshot: cmd.workflow_snapshot,
        submission_id: submission_id,
        run_id: run_id
      }}
    end
  end

  @impl true
  def handle_command(_state, _command), do: :unhandled

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp validate_prompt(prompt) when is_binary(prompt) and byte_size(prompt) > 0, do: {:ok, prompt}
  defp validate_prompt(_), do: {:error, {:invalid_envelope, :missing_prompt}}

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
