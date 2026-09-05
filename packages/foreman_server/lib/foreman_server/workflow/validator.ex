defmodule ForemanServer.Workflow.Validator do
  @moduledoc """
  Workflow definition validation against the real parsed manifest shape
  (string keys, no `id`/`steps`/`skill` fields).

  Real manifests use:
    - top-level: `name` (required), `description` (optional), `phases` (required list)
    - phase-level: `name` (required), `command`/`prompt`/`bash` (one required),
      `skill` extracted from `command` via `/skill:(\S+)` pattern

  TRD-2026-4212be7e / HLW-T003 / TRD-093, updated for HLW-T004 / TRD-094.
  """
  @known_skills ~w(
    create-prd refine-prd create-trd refine-trd
    implement-trd fix-issue
    ensemble-full-create-prd ensemble-full-refine-prd
    ensemble-full-create-trd ensemble-full-create-trd-foreman
    ensemble-full-implement-trd ensemble-full-implement-trd-beads
    ensemble-full-refine-trd-foreman
    ensemble-fix-issue
  )
  # Regex to extract skill name from a command string, e.g.
  # "/skill:ensemble-full-implement-trd ..." → "ensemble-full-implement-trd"
  @skill_from_command ~r{^/skill:(\S+)}

  @type validation_error ::
          :missing_name
          | :missing_phases
          | :empty_phases
          | {:unknown_skill, String.t()}
          | {:invalid_phase_entry, non_neg_integer()}
          | {:missing_phase_name, non_neg_integer()}
          | {:missing_phase_action, non_neg_integer()}
          | {:invalid_stall_detection, non_neg_integer(), term()}

  @spec validate(map()) :: :ok | {:error, validation_error()}
  def validate(workflow) when is_map(workflow) do
    cond do
      missing_key?(workflow, "name") ->
        {:error, :missing_name}

      missing_key?(workflow, "phases") ->
        {:error, :missing_phases}

      Map.get(workflow, "phases", []) == [] ->
        {:error, :empty_phases}

      true ->
        validate_phases(Map.get(workflow, "phases", []), 0)
    end
  end

  def validate(_), do: {:error, {:invalid_workflow, :not_a_map}}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp missing_key?(map, key), do: not Map.has_key?(map, key)

  defp validate_phases([], _index), do: :ok

  defp validate_phases([phase | rest], index) do
    with :ok <- validate_phase(phase, index) do
      validate_phases(rest, index + 1)
    end
  end

  defp validate_phase(phase, index) when is_map(phase) do
    cond do
      missing_key?(phase, "name") ->
        {:error, {:missing_phase_name, index}}

      missing_key?(phase, "command") and missing_key?(phase, "prompt") and
          missing_key?(phase, "bash") ->
        {:error, {:missing_phase_action, index}}

      true ->
        with :ok <- validate_stall_detection(phase, index) do
          if Map.has_key?(phase, "command") do
            validate_skill_from_command(phase["command"], index)
          else
            :ok
          end
        end
    end
  end

  defp validate_phase(_non_map, index), do: {:error, {:invalid_phase_entry, index}}

  # Reuses `PhaseSpec.fetch/2`'s accepted-spellings table rather than
  # hand-checking the string key "stall_detection" alone, so an atom or
  # camelCase spelling that `PhaseSpec.normalize/1` accepts cannot pass
  # validation and then raise later at normalize time (AGENTS.md §5.4b).
  defp validate_stall_detection(phase, index) do
    case ForemanServer.Workflow.PhaseSpec.fetch(phase, :stall_detection) do
      nil ->
        :ok

      value ->
        case ForemanServer.Workflow.StallPolicy.normalize(value) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:invalid_stall_detection, index, reason}}
        end
    end
  end

  defp validate_skill_from_command(command, _index) when is_binary(command) do
    case Regex.run(@skill_from_command, command) do
      [_, skill | _] ->
        if skill in @known_skills do
          :ok
        else
          {:error, {:unknown_skill, skill}}
        end

      nil ->
        # No /skill: prefix — not an Ensemble skill invocation; skip validation.
        :ok
    end
  end

  defp validate_skill_from_command(_non_string, _index), do: :ok
end
