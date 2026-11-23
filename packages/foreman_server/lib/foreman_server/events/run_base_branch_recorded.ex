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
  cut (`RunExecutor.foreman_env/3` exports it as `FOREMAN_BASE_SHA`). Recording
  it keeps the PR comparison base reproducible after the branch moves. It is
  absent on pre-existing events and on the secondary-repo recording path.
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
