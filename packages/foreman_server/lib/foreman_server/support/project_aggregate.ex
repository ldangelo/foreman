defmodule ForemanServer.AC1ProjectAggregate do
  # Commanded-style Project aggregate — struct IS the per-stream state.
  # execute(state, cmd) — state first; apply(state, event) — state first.
  # States: nil (not registered) → :registered → :archived

  alias ForemanServer.Events.{ProjectRegistered, ProjectArchived}

  defstruct [:project_id, :path, :status]

  def initial_state, do: %__MODULE__{}

  # RegisterProject: initial command
  def execute(%__MODULE__{status: nil}, %ForemanServer.Commands.RegisterProject{} = cmd) do
    %ProjectRegistered{
      project_id: cmd.project_id,
      path: cmd.path || "/tmp/#{cmd.project_id}"
    }
  end

  def execute(%__MODULE__{status: s}, %ForemanServer.Commands.RegisterProject{})
      when s != nil do
    {:error, :already_registered}
  end

  # ArchiveProject: from :registered
  def execute(%__MODULE__{status: :registered}, %ForemanServer.Commands.ArchiveProject{}) do
    %ProjectArchived{}
  end

  def execute(%__MODULE__{status: s}, %ForemanServer.Commands.ArchiveProject{})
      when s != :registered do
    {:error, :not_registered}
  end

  def execute(_state, _cmd), do: :unhandled

  # apply/2 — state first
  def apply(state, %ProjectRegistered{} = event) do
    %{state | project_id: event.project_id, path: event.path, status: :registered}
  end

  def apply(state, %ProjectArchived{}) do
    %{state | status: :archived}
  end
end
