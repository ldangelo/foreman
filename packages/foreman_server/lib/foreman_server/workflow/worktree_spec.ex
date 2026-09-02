defmodule ForemanServer.Workflow.WorktreeSpec do
  @moduledoc """
  Canonical atom-keyed representation of a workflow's `worktree:` block.

  **The block is WORKFLOW-level, not phase-level.** A run has exactly one
  worktree for its whole execution, so "does this run get a worktree, cut from
  where, on which branch, cleaned up when" is a property of the workflow — there
  is nothing for a phase to decide. The block is declared at the top level of
  the manifest, beside `name:` and `phases:`:

      name: implement-trd
      worktree:
        enabled: true
        base: "{{implementation.source_revision}}"
        branch: foreman/{task_id}
        cleanup: never
      phases:
        - name: implement-trd
          command: "..."

  It used to be declared per phase, and `RunExecutor` read it off each phase
  spec. That was incoherent once the worktree became run-scoped: N phases could
  each declare a different `base`/`branch`/`cleanup` for one shared resource, and
  only the first phase's block could possibly be honored. Worse, the two code
  paths it selected between were not interchangeable — declaring the block sent
  the run through a provisioning function that required an ImplementationContext,
  so adding `worktree: {enabled: true}` to a plan-type workflow did not restate
  the default, it broke the run. There is now one provisioning path and the block
  is legal on every workflow.

  Fields, all optional:

    * `enabled` — `false` opts the whole workflow out of worktrees. Default true.
    * `base` — ref the worktree is cut from. When the run carries an
      ImplementationContext this MUST resolve to the frozen `source_revision`
      (asserted by `RunExecutor`); otherwise the project checkout's `HEAD` is
      used and a declared `base` is resolved against the project root.
    * `branch` — branch template. `{task_id}` and `{run_id}` are substituted.
      Default `foreman/{task_id}`.
    * `path` — leaf directory name under
      `~/.foreman/worktrees/<project_id>/<run_id>/`. `{run_id}` is substituted.
      Default `workspace`.
    * `cleanup` — `never` | `always` | `on_success`. Default `never`.
      `on_success` retains the worktree of a failed run so it can be inspected,
      which is the reason the mode exists. Validated by
      `RunExecutor.worktree_cleanup/1`, which rejects any other value rather
      than defaulting.

  `{phase}` is deliberately NOT substituted. It was meaningful only while each
  phase had its own worktree; a run-scoped branch or directory named after one
  phase of several is a misnomer.

  Unrecognized keys are dropped — they were never readable downstream, since
  nothing knows to look for them. Absent keys are dropped rather than set to
  `nil`, because `nil` is indistinguishable from "declared nothing" at the read
  site and poisons any caller written as `value || fallback` (AGENTS.md §5.4b).
  """

  # {canonical_atom, [accepted source keys, in precedence order]}
  @fields [
    {:enabled, [:enabled, "enabled"]},
    {:base, [:base, "base"]},
    {:branch, [:branch, "branch"]},
    {:path, [:path, "path"]},
    {:cleanup, [:cleanup, "cleanup"]}
  ]

  @doc """
  Normalize a workflow's `worktree:` block, or `nil` when it declares none.

  `nil` is meaningful and distinct from `%{}`: it means the workflow made no
  declaration at all, so every default applies.
  """
  @spec normalize(map() | nil) :: map() | nil
  def normalize(nil), do: nil

  def normalize(raw) when is_map(raw) do
    Enum.reduce(@fields, %{}, &put_field(&1, raw, &2))
  end

  # A non-map declaration is MALFORMED, not absent, and the two must not share a
  # return value: `nil` means "declared nothing, all defaults apply", so mapping
  # `worktree: "yes"` onto it silently provisions the default-ON worktree for a
  # manifest nobody could read. That is the absent-vs-malformed conflation
  # AGENTS.md 5.3 forbids, and it contradicts this module's own reason for
  # existing — `fetch_any/2` above goes out of its way to distinguish "absent"
  # from "present and falsy".
  #
  # `Interpreter.validate_worktree!/2` already rejects a non-map at load, so
  # reaching here with one means the value bypassed that boundary: a programming
  # error, which 5.3 says to raise on rather than encode as a return value.
  def normalize(other) do
    raise ArgumentError,
          "worktree declaration must be a mapping or absent, got: #{inspect(other)}"
  end

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
      {:ok, value} -> value
      :error -> fetch_any(source_map, rest)
    end
  end
end
