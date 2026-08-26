defmodule ForemanServer.Workflow.ErrorReporter do
  @moduledoc """
  Invalid workflow error reporting. TRD-2026-4212be7e / HLW-T004 / TRD-094.

  Error tuples produced by Validator.validate/1 against the real string-keyed
  manifest shape (from Interpreter.load/1).  All errors are wrapped in the
  uniform `{:error, reason}` shape returned by Validator; `format/1` receives
  the bare `reason` (after the outer `{:error, ...}` wrapper is stripped by
  callers).  Error messages are descriptive and safe to surface to operators.
  """
  require Logger

  def report(reason) do
    Logger.error("Workflow error: #{format(reason)}")
    format(reason)
  end

  # All format/1 clauses receive the bare reason (after {:error, wrapper stripped).

  # Validator.validate/1 top-level errors
  defp format(:missing_name),
    do: "Workflow is missing the required 'name' field"
  defp format(:missing_phases),
    do: "Workflow is missing the required 'phases' field"
  defp format(:empty_phases),
    do: "Workflow 'phases' list is empty; at least one phase is required"

  # Skill validation
  defp format({:unknown_skill, skill}),
    do: "Unknown skill: '#{skill}'. Known skills: create-prd, refine-prd, create-trd, refine-trd, implement-trd, fix-issue, ensemble-fix-issue, ensemble-full-create-prd, ensemble-full-refine-prd, ensemble-full-create-trd, ensemble-full-create-trd-foreman, ensemble-full-implement-trd, ensemble-full-implement-trd-beads, ensemble-full-refine-trd-foreman."

  # Validator.validate_phase/2 errors — bare inner tuples (outer {:error, ..} stripped by caller)
  defp format({:missing_phase_name, index}),
    do: "Phase #{index} is missing the required 'name' field"
  defp format({:missing_phase_action, index}),
    do: "Phase #{index} is missing a required action field (one of: command, prompt, bash)"

  # Catch-all
  defp format(other), do: "Workflow error: #{inspect(other)}"
end
