defmodule ForemanServer.Workflow.ErrorReporter do
  @moduledoc "Invalid workflow error reporting. TRD-2026-4212be7e / HLW-T004 / TRD-094."
  require Logger
  def report(reason) do
    Logger.error("Workflow error: #{format(reason)}")
    format(reason)
  end
  defp format({:unknown_skill, skill}), do: "Unknown skill: #{skill}. Known skills: create-prd, refine-prd, etc."
  defp format(:missing_id), do: "Workflow missing required 'id' field"
  defp format(:missing_steps), do: "Workflow has no steps"
  defp format(:missing_step_name), do: "Step missing 'name' field"
  defp format(:missing_skill), do: "Step missing 'skill' field"
  defp format(other), do: "Workflow error: #{inspect(other)}"
end