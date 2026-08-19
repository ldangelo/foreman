defmodule ForemanServer.Workflow.StepSequencer do
  @moduledoc """
  Step sequencer that propagates terminal status (completed/failed/blocked) between steps.
  TRD-2026-4212be7e / WFD-T003 / TRD-066.
  """
  require Logger
  @terminal_states [:completed, :failed, :blocked]

  def propagate_terminal(prev_status, next_step) do
    cond do
      prev_status == :failed ->
        Logger.warning("Previous step failed; not running #{next_step}")
        {:halt, :failed}
      prev_status == :blocked ->
        Logger.warning("Previous step blocked; not running #{next_step}")
        {:halt, :blocked}
      prev_status in @terminal_states ->
        {:cont, next_step}
      true ->
        {:cont, next_step}
    end
  end

  def sequence(steps, initial_status \\ :pending) do
    Enum.reduce_while(steps, {:ok, initial_status}, fn step, {:ok, status} ->
      case propagate_terminal(status, step) do
        {:halt, terminal} -> {:halt, {:halted, terminal, step}}
        {:cont, next_step} -> {:cont, {:ok, :completed}}
      end
    end)
  end
end
