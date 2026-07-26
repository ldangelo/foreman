defmodule ForemanServer.AC1RunAggregate do
  defstruct [:run_id, :task_id, :status]

  # StartRun: initial command
  def execute(%ForemanServer.AC1RunAggregate{status: nil}, %ForemanServer.Commands.StartRun{} = cmd) do
    %ForemanServer.Events.RunStarted{run_id: cmd.run_id, task_id: cmd.task_id}
  end

  # CompleteRun: only succeeds if already running (state-gated)
  def execute(%ForemanServer.AC1RunAggregate{status: :running}, %ForemanServer.Commands.CompleteRun{}) do
    %ForemanServer.Events.RunCompleted{}
  end

  # CompleteRun rejected if not in :running state
  def execute(%ForemanServer.AC1RunAggregate{}, %ForemanServer.Commands.CompleteRun{}) do
    {:error, :not_running}
  end

  # apply/2 — state first, event second
  def apply(state, %ForemanServer.Events.RunStarted{} = event) do
    %{state | run_id: event.run_id, task_id: event.task_id, status: :running}
  end

  def apply(state, %ForemanServer.Events.RunCompleted{}) do
    %{state | status: :completed}
  end
end
