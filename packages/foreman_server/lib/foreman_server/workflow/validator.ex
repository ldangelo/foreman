defmodule ForemanServer.Workflow.Validator do
  @moduledoc "Workflow definition validation. TRD-2026-4212be7e / HLW-T003 / TRD-093."
  @known_skills ~w(create-prd refine-prd create-trd refine-trd implement-trd fix-issue)

  def validate(workflow_def) do
    cond do
      not is_map_key(workflow_def, :id) -> {:error, :missing_id}
      not is_map_key(workflow_def, :steps) or workflow_def.steps == [] -> {:error, :missing_steps}
      true ->
        Enum.reduce_while(workflow_def.steps, :ok, fn step, acc ->
          case validate_step(step) do
            :ok -> {:cont, acc}
            {:error, _} = err -> {:halt, err}
          end
        end)
    end
  end

  defp validate_step(step) do
    cond do
      not is_map_key(step, :name) -> {:error, :missing_step_name}
      not is_map_key(step, :skill) -> {:error, :missing_skill}
      step.skill not in @known_skills -> {:error, {:unknown_skill, step.skill}}
      true -> :ok
    end
  end
end