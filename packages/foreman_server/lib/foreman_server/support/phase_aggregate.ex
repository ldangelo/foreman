defmodule ForemanServer.AC1PhaseAggregate do
  # Commanded-style Phase aggregate — struct IS the per-stream state.
  # execute(state, cmd) — state first; apply(state, event) — state first.
  # States: nil (not started) → :running → :completed

  alias ForemanServer.Events.{PhaseStarted, PhaseCompleted}

  defstruct [:phase_id, :run_id, :status]

  def initial_state, do: %__MODULE__{}

  # StartPhase: initial command
  def execute(%__MODULE__{status: nil}, %ForemanServer.Commands.StartPhase{} = cmd) do
    %PhaseStarted{
      phase_id: cmd.phase_id,
      run_id: cmd.run_id,
      index: cmd.index || 1,
      name: cmd.name || "phase",
      attempt: cmd.attempt || 1,
      artifact_template: cmd.artifact_template || "{run.id}.md"
    }
  end

  def execute(%__MODULE__{status: s}, %ForemanServer.Commands.StartPhase{})
      when s != nil do
    {:error, :already_started}
  end

  # CompletePhase: from :running
  def execute(%__MODULE__{status: :running}, %ForemanServer.Commands.CompletePhase{} = cmd) do
    %PhaseCompleted{
      phase_id: cmd.phase_id,
      run_id: cmd.run_id || "",
      index: cmd.index || 1,
      artifact_path: cmd.artifact_path || "",
      artifact_sha256: cmd.artifact_sha256 || "",
      artifact_bytes: cmd.artifact_bytes || 0
    }
  end

  def execute(%__MODULE__{status: s}, %ForemanServer.Commands.CompletePhase{})
      when s != :running do
    {:error, :not_running}
  end

  def execute(_state, _cmd), do: :unhandled

  # apply/2 — state first
  def apply(state, %PhaseStarted{} = event) do
    %{state | phase_id: event.phase_id, run_id: event.run_id, status: :running}
  end

  def apply(state, %PhaseCompleted{}) do
    %{state | status: :completed}
  end
end
