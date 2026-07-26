defmodule ForemanServer.AC1TaskAggregate do
  # Commanded-style Task aggregate — struct IS the per-stream state.
  # execute(state, cmd) — state first; apply(state, event) — state first.
  # States: nil (not created) → :created → :closed

  alias ForemanServer.Events.{TaskCreated, TaskClosed}

  defstruct [:task_id, :project_id, :status]

  def initial_state, do: %__MODULE__{}

  # CreateTask: initial command
  def execute(%__MODULE__{status: nil}, %ForemanServer.Commands.CreateTask{} = cmd) do
    %TaskCreated{task_id: cmd.task_id, project_id: cmd.project_id || "default"}
  end

  def execute(%__MODULE__{status: s}, %ForemanServer.Commands.CreateTask{})
      when s != nil do
    {:error, :already_exists}
  end

  # CloseTask: from :created
  def execute(%__MODULE__{status: :created}, %ForemanServer.Commands.CloseTask{}) do
    %TaskClosed{}
  end

  def execute(%__MODULE__{status: s}, %ForemanServer.Commands.CloseTask{})
      when s != :created do
    {:error, :not_created}
  end

  def execute(_state, _cmd), do: :unhandled

  # apply/2 — state first
  def apply(state, %TaskCreated{} = event) do
    %{state | task_id: event.task_id, project_id: event.project_id, status: :created}
  end

  def apply(state, %TaskClosed{}) do
    %{state | status: :closed}
  end
end
