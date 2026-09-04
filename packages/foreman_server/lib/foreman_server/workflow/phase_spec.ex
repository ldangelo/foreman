defmodule ForemanServer.Workflow.PhaseSpec do
  @moduledoc """
  Canonical atom-keyed representation of a single workflow phase.

  A phase reaches the executor by two routes with different key conventions:

    * **fresh** — `Workflow.Interpreter` parses YAML into string-keyed maps and
      `Workflow.Catalog` decorates them with atom keys, producing a hybrid map
      where `:command` and `"command"` both exist.
    * **replayed** — the resolved phase is frozen into `workflow_snapshot` on a
      domain event, so a JSON round-trip converts every atom key back to a
      string before the projection hands it to the executor.

  Consumers used to compensate per read with
  `Map.get(spec, :name) || Map.get(spec, "name")`, which is the defect this
  module removes: normalize once at the boundary (`AGENTS.md` §5.4), then read
  atoms everywhere downstream.

  `normalize/1` accepts either convention and returns atom keys only. Every
  target atom is a literal here, so caller-supplied YAML can never mint atoms.
  Unrecognized keys are dropped — they were never readable downstream, since
  nothing knows to look for them.
  """

  # {canonical_atom, [accepted source keys, in precedence order]}
  @fields [
    {:name, [:name, "name"]},
    {:prompt, [:prompt, "prompt"]},
    {:prompt_path, [:prompt_path, "prompt_path"]},
    {:artifact_template, [:artifact_template, "artifact_template", "artifact"]},
    {:command, [:command, "command"]},
    {:bash, [:bash, "bash"]},
    {:required_file, [:required_file, "required_file", "requiredFile"]},
    {:index, [:index, "index"]},
    {:models, [:models, "models"]},
    {:max_turns, [:max_turns, "max_turns", "maxTurns"]},
    {:timeout_minutes, [:timeout_minutes, "timeout_minutes", "timeoutMinutes"]},
    {:mail, [:mail, "mail"]},
    {:context, [:context, "context"]},
    # Phase-level, unlike `worktree:`: each phase produces its own output, so
    # whether that output becomes a commit is a per-phase question. Absent is
    # NOT the same as `false` — `fetch_any/2` below preserves a present `false`
    # — because absent means "default" (commit) and `false` means "defer".
    {:commit, [:commit, "commit"]},
    {:stack_pr, [:stack_pr, "stack_pr"]}
  ]

  @doc """
  Normalize one phase map to canonical atom keys.

  `:action` is derived rather than trusted, so it cannot disagree with the
  `command`/`bash`/`prompt` fields it describes.

  A phase has no `worktree:` key. The block is workflow-level — see
  `ForemanServer.Workflow.WorktreeSpec` — because a run has exactly one worktree
  for its whole execution, leaving a phase nothing to decide about it. It was
  read off the phase spec while worktrees were per-phase.
  """
  @spec normalize(map()) :: map()
  def normalize(phase) when is_map(phase) do
    spec = Enum.reduce(@fields, %{}, &put_field(&1, phase, &2))

    Map.put(spec, :action, derive_action(spec))
  end

  @doc "Normalize a list of phase maps, preserving order."
  @spec normalize_all([map()]) :: [map()]
  def normalize_all(phases) when is_list(phases) do
    Enum.map(phases, &normalize/1)
  end

  # An ABSENT source key is omitted, not stored as `nil`. AGENTS.md 5.4b states
  # this directly ("Never insert `nil` for an absent key"), and `commit:` is the
  # field that makes it matter: `nil` would be a third state alongside the two
  # the operator can write, leaving "declared nothing" and "declared the
  # default" indistinguishable to anything using `Map.has_key?/2`. Readers using
  # `Map.get/2` are unaffected — an omitted key already reads as `nil`.
  defp put_field({key, sources}, source_map, acc) do
    case fetch_any(source_map, sources) do
      nil -> acc
      value -> Map.put(acc, key, value)
    end
  end

  # `Enum.find_value/2` cannot express this: it treats a legitimately-present
  # `false` as "keep looking", which silently turned `worktree: {enabled: false}`
  # into `nil` — the one value that actually disables a worktree. Distinguish
  # "absent" from "present and falsy" explicitly.
  defp fetch_any(_source_map, []), do: nil

  defp fetch_any(source_map, [source | rest]) do
    case Map.fetch(source_map, source) do
      {:ok, nil} -> fetch_any(source_map, rest)
      {:ok, value} -> value
      :error -> fetch_any(source_map, rest)
    end
  end

  defp derive_action(spec) do
    cond do
      present?(spec[:command]) -> :command
      present?(spec[:bash]) -> :bash
      true -> :prompt
    end
  end

  defp present?(value), do: is_binary(value) and value != ""
end
