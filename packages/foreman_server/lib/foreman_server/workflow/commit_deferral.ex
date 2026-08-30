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

  ## Total, by construction

  `pending_phase/1` never raises. It runs during manifest load, where a
  malformed phase list has not yet been rejected, so a non-map entry has to be
  survivable rather than a crash from inside a validator that exists to produce
  a good error message. A non-map entry counts as non-deferring — it cannot
  carry `commit: false` — which matches how the surrounding validators treat
  entries they cannot read.
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
  @spec pending_phase(list()) :: non_neg_integer() | nil
  def pending_phase(phases) when is_list(phases) do
    phases
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {phase, index}, pending ->
      if deferred?(phase) do
        # `pending || index` latches the FIRST index of an uncommitted run, so a
        # second consecutive deferral does not overwrite where the run started.
        pending || index
      else
        nil
      end
    end)
  end

  def pending_phase(_other), do: nil

  @doc """
  Whether a phase defers its work.

  Only a literal boolean `false` defers. An ABSENT `commit:` key commits, and is
  deliberately not the same thing as `commit: false` — `Interpreter` refuses any
  other value at load, so a non-boolean never reaches here.
  """
  @spec deferred?(term()) :: boolean()
  def deferred?(phase) when is_map(phase), do: Map.get(phase, "commit") == false
  def deferred?(_phase), do: false
end
