defmodule ForemanServer.Agents.ZeroCandidatesHandler do
  @moduledoc "Handles zero-candidates from LiteLLM. TRD-2026-4212be7e / LGL-T003 / TRD-044."

  def format_error(excluded_filters) do
    %{
      kind: :zero_candidates,
      message: "No models matched the capability filters",
      excluded_filters: excluded_filters,
      suggestion: "Relax filters or add model to capability mapping"
    }
  end
end
