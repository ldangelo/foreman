defmodule ForemanServer.AC1RunAggregate do
  defstruct [:run_id, :task_id, :status]

  # execute/2 — state first, command second (Commanded 1.4.10 confirmed)
  def execute(%ForemanServer.AC1RunAggregate{} = state, %ForemanServer.Commands.StartRun{} = cmd) do
    %ForemanServer.Events.RunStarted{run_id: cmd.run_id, task_id: cmd.task_id}
  end

  # apply/2 — state first, event second (Commanded 1.4.10 confirmed)
  def apply(state, %ForemanServer.Events.RunStarted{} = event) do
    %{state | run_id: event.run_id, task_id: event.task_id, status: :running}
  end
end
