defmodule ForemanServer.AC1WorkerAggregate do
  # Commanded-style Worker aggregate — struct IS the per-stream state.
  # execute(state, cmd) — state first; apply(state, event) — state first.
  # States: nil (not started) → :running → :exited

  alias ForemanServer.Events.{WorkerStarted, WorkerExited}

  defstruct [:worker_id, :run_id, :status]

  def initial_state, do: %__MODULE__{}

  # StartWorker: initial command
  def execute(%__MODULE__{status: nil}, %ForemanServer.Commands.StartWorker{} = cmd) do
    %WorkerStarted{worker_id: cmd.worker_id, run_id: cmd.run_id}
  end

  def execute(%__MODULE__{status: s}, %ForemanServer.Commands.StartWorker{})
      when s != nil do
    {:error, :already_started}
  end

  # ExitWorker: from :running
  def execute(%__MODULE__{status: :running}, %ForemanServer.Commands.ExitWorker{}) do
    %WorkerExited{}
  end

  def execute(%__MODULE__{status: s}, %ForemanServer.Commands.ExitWorker{})
      when s != :running do
    {:error, :not_running}
  end

  def execute(_state, _cmd), do: :unhandled

  # apply/2 — state first
  def apply(state, %WorkerStarted{} = event) do
    %{state | worker_id: event.worker_id, run_id: event.run_id, status: :running}
  end

  def apply(state, %WorkerExited{}) do
    %{state | status: :exited}
  end
end
