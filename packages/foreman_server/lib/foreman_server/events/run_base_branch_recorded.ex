defmodule ForemanServer.Events.RunBaseBranchRecorded do
  @moduledoc """
  Typed event emitted when the run's PR base branch is durably recorded.

  `RunExecutor.remember_run_base_branch/1` resolves the base branch once
  (the checkout's branch at the moment the first phase starts) and holds
  it in memory. Persisting it here means a resumed executor reads the
  ORIGINAL base branch back from the projection instead of re-deriving
  it from whatever branch the registered checkout happens to be on at
  resume time — the failure mode this event exists to close.

  `repo_id` (E12) is ABSENT for the run's primary repository and present for a
  secondary repository's base branch.

  `base_sha` is the commit `base_branch` pointed at when the run worktree was
  cut. Recording it keeps the PR comparison base reproducible after the branch
  moves. Producers omit the field when no commit could be resolved, so it is
  absent from the event rather than stored as `nil`, and it stays absent on
  pre-existing events. It is written by the producers of this event
  (`RunExecutor` for the primary and for a secondary repository,
  `Workflow.RepoAttach` for a secondary repository) and read by
  `ProjectionStore`, which surfaces it on the run view as `base_sha`
  (`repo_base_shas`, keyed by `repo_id`, for a secondary repository).
  """
  @enforce_keys [:run_id, :base_branch]
  @type t :: %__MODULE__{
          run_id: String.t(),
          base_branch: String.t(),
          base_sha: String.t() | nil,
          repo_id: String.t() | nil,
          sequence: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [:run_id, :base_branch, :base_sha, :repo_id, :sequence]
end
