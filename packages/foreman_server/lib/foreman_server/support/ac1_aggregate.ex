defmodule ForemanServer.AC1RunAggregate do
  # Commanded-style Run aggregate — struct IS the per-stream state.
  # execute(state, cmd) — state first; apply(state, event) — state first.
  # States: nil → :running → :completed

  alias ForemanServer.Events.{RunStarted, RunCompleted}

  defstruct [:run_id, :task_id, :status]

  def initial_state, do: %__MODULE__{}

  # StartRun: initial command
  def execute(%__MODULE__{status: nil}, %ForemanServer.Commands.StartRun{} = cmd) do
    %RunStarted{run_id: cmd.run_id, task_id: cmd.task_id}
  end

  # CompleteRun: only succeeds if already running (state-gated)
  def execute(%__MODULE__{status: :running}, %ForemanServer.Commands.CompleteRun{}) do
    %RunCompleted{}
  end

  def execute(%__MODULE__{}, %ForemanServer.Commands.CompleteRun{}) do
    {:error, :not_running}
  end

  def execute(_state, _cmd), do: :unhandled

  # apply/2 — state first
  def apply(state, %RunStarted{} = event) do
    %{state | run_id: event.run_id, task_id: event.task_id, status: :running}
  end

  def apply(state, %RunCompleted{}) do
    %{state | status: :completed}
  end
end
