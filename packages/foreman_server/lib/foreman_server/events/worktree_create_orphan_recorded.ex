defmodule ForemanServer.Events.WorktreeCreateOrphanRecorded do
  @moduledoc """
  Durable record of a worktree whose `vcs.worktree.create` command's
  dispatch failed AFTER the Git side effect succeeded.

  Distinct from `WorktreeCreated` so the orphan-record projection is
  independent. Records `worktree_path` as a required field (per TRD
  Decision 8) so future `BootReconciliation` can surface the on-disk
  path for operator recovery.

  Required correlation tuple: `operation_id`, `project_id`, `run_id`,
  `phase_id`. `worktree_path` is the on-disk path the operator must
  clean.
  """
  @enforce_keys [:operation_id, :project_id, :run_id, :phase_id, :worktree_path]
  @type t :: %__MODULE__{
          operation_id: String.t(),
          project_id: String.t(),
          run_id: String.t(),
          phase_id: String.t(),
          worktree_path: String.t(),
          repo_path: String.t() | nil,
          reason: String.t() | nil,
          branch: String.t() | nil
        }
  @derive Jason.Encoder
  defstruct [
    :operation_id,
    :project_id,
    :run_id,
    :phase_id,
    :worktree_path,
    :repo_path,
    :reason,
    :branch
  ]
end
