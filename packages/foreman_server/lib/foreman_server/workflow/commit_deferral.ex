defmodule ForemanServer.Workflow.CommitDeferral do
  @moduledoc """
  Answers one question about a phase list: is any phase's work still
  uncommitted once every phase has run?

  A phase declaring `commit: false` DEFERS its work, leaving the changes in the
  run's worktree for a later phase to commit — which is how several phases are
  batched into a single commit. A phase that commits absorbs everything pending
  before it. So "pending at the end" means work no phase will ever commit.

  ## Why this is a module and not a private function

  `Interpreter` is cached by `Workflow.Catalog` and parses a manifest with no
  `run_id` in scope, so it cannot emit anything against a run. Deciding whether
  work is left pending and REPORTING that fact therefore have to be separable:
  this module is the deciding half, and `RunExecutor` — which does have the run
  — is the reporting half. Both `Interpreter.validate_commit_cleanup!/3` and
  `RunExecutor`'s run-terminal warning read this one predicate, so they cannot
  disagree about what "pending" means.

  ## Total over its contract, loud outside it

  Both entry points take a list of phase maps and raise `FunctionClauseError` on
  anything else. There is no catch-all: "nothing is deferred" is the one answer
  that silences BOTH consumers — the unsatisfiable-cleanup refusal at load and
  the uncommitted-work warning at run end — so inventing it for input this
  module cannot read would turn unreadable input into a silent all-clear
  (AGENTS.md §5.2).

  An earlier version of this section claimed the opposite, and its reasoning is
  worth recording because it was wrong in a checkable way: it said
  `pending_phase/1` "runs during manifest load, where a malformed phase list has
  not yet been rejected", so tolerance was needed to avoid crashing from inside
  a validator that exists to produce a good error message. The ordering is the
  other way around. `Interpreter.load!/1` runs `validate_required_fields!` —
  which rejects a non-list `phases` and any non-map phase entry, each with a
  located message — BEFORE `validate_commits!`, and `parse_yaml!` rejects a
  non-mapping entry even earlier, naming file and line. The tolerance protected
  no error message; it only meant that if these functions were ever reached with
  garbage, they would answer "all clear".
  """

  @doc """
  Returns the zero-based index of the EARLIEST phase whose work is still
  uncommitted after the whole list has run, or `nil` when every deferral was
  absorbed by a later committing phase.

  The earliest index is the useful one: with consecutive deferrals the operator
  needs to know where the uncommitted run of phases begins, not which phase
  happened to be last.

      iex> pending_phase([%{"commit" => false}, %{"commit" => true}])
      nil

      iex> pending_phase([%{"commit" => true}, %{"commit" => false}])
      1

      iex> pending_phase([%{"commit" => false}, %{"commit" => false}])
      0
  """
  # No catch-all clause, deliberately. A non-list has no answer to "which phase
  # left work pending", and returning `nil` would report the SAFE answer — no
  # deferral — for input this module cannot read. That answer suppresses the
  # uncommitted-work warning and the unsatisfiable-cleanup refusal both, so the
  # one shape that must never be guessed would be guessed silently. Both callers
  # hold a validated list of maps (`Interpreter` a manifest it just parsed,
  # `RunExecutor` specs from `executed_phase_specs/1`), so anything else is a
  # programming error and `FunctionClauseError` is the correct outcome
  # (AGENTS.md §5.2: a crash beats a lie).
  @spec pending_phase(list()) :: non_neg_integer() | nil
  def pending_phase(phases) when is_list(phases), do: fold_pending(phases, &deferred?/1)

  @doc """
  The same predicate over NORMALIZED `PhaseSpec` maps, which carry the atom key
  `:commit` rather than the manifest's `"commit"`.

  Two entry points rather than one function reading both keys: the two shapes
  are two different boundaries — `Interpreter` reads a manifest it just parsed,
  `RunExecutor` reads specs normalized from a JSON-round-tripped snapshot — and
  a `Map.get(m, :commit) || Map.get(m, "commit")` hedge would leave neither
  boundary owning the convention (AGENTS.md §5.4). Here each caller names the
  shape it actually holds, and the shared fold guarantees they cannot disagree
  about what "pending" MEANS, which is the property that matters.
  """
  @spec pending_phase_spec(list()) :: non_neg_integer() | nil
  def pending_phase_spec(specs) when is_list(specs), do: fold_pending(specs, &spec_deferred?/1)

  defp fold_pending(phases, deferred?) do
    phases
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {phase, index}, pending ->
      if deferred?.(phase) do
        # `pending || index` latches the FIRST index of an uncommitted run, so a
        # second consecutive deferral does not overwrite where the run started.
        pending || index
      else
        nil
      end
    end)
  end

  @doc """
  Whether a phase defers its work.

  Only a literal boolean `false` defers. An ABSENT `commit:` key commits, and is
  deliberately not the same thing as `commit: false` — `Interpreter` refuses any
  other value at load, so a non-boolean never reaches here.

  A non-map phase raises rather than answering `false`, for the reason given on
  `pending_phase/1`: "this phase commits" is not a safe default to invent for an
  entry that cannot be read.
  """
  @spec deferred?(map()) :: boolean()
  def deferred?(phase) when is_map(phase), do: Map.get(phase, "commit") == false

  # The normalized counterpart. `PhaseSpec.normalize/1` OMITS an absent key
  # rather than storing `nil`, so `Map.get/2` returning `nil` here means the
  # phase declared nothing — which commits.
  defp spec_deferred?(spec) when is_map(spec), do: Map.get(spec, :commit) == false
end
