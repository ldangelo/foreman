defmodule ForemanServer.Workflow.StepSequencer do
  @moduledoc """
  Step sequencer that propagates terminal status (completed/failed/blocked) between steps.
  TRD-2026-4212be7e / WFD-T003 / TRD-066.
  """
  require Logger

  @doc """
  Propagate terminal status from previous step to next step.
  Returns {:halt, reason} if sequence should halt, {:cont, nil} if continue.
  """
  def propagate_terminal(prev_status, next_step) do
    cond do
      prev_status == :failed ->
        Logger.warning("Previous step failed; not running #{inspect(next_step)}")
        {:halt, :failed}
      prev_status == :blocked ->
        Logger.warning("Previous step blocked; not running #{inspect(next_step)}")
        {:halt, :blocked}
      true ->
        {:cont, nil}
    end
  end

  @doc """
  Sequence through steps, propagating terminal status between them.
  Steps are data terms (atoms, maps, etc.) - not functions.
  RunExecutor calls this to determine sequencing; phase execution
  happens in RunExecutor after this returns.

  Returns:
    - {:ok, final_status} when all steps complete or halt on completed
    - {:halted, terminal, step} when halted early due to failed/blocked
  """
  def sequence(steps, initial_status \\ :pending) do
    Enum.reduce_while(steps, {:ok, initial_status}, fn step, {:ok, prev_status} ->
      case propagate_terminal(prev_status, step) do
        {:halt, terminal} ->
          {:halt, {:halted, terminal, step}}
        {:cont, _} ->
          {:cont, {:ok, :completed}}
      end
    end)
  end
end
