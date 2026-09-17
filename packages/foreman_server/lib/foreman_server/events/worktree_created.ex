defmodule ForemanServer.Events.WorktreeCreated do
  @moduledoc """
  Emitted when Foreman creates a managed VCS worktree for a run.

  `operation_id` is `"wt-" <> run_id` — one worktree per RUN, not per
  phase (`create_run_worktree/2` in `RunExecutor`). `phase_id` records
  which phase triggered the create but is not part of the correlation key:
  a re-attempted create for a later phase re-emits the same `operation_id`
  and finds the same projection slot. This is also how a resumed run finds
  its worktree to rehydrate (`find_resumable_worktree/1`) rather than
  re-provisioning one.

  Worktree configuration fields are optional on the event because the
  aggregate's source of truth is the typed workflow snapshot (immutable at
  task approval). They are recorded here so projections and the
  WorktreeCreateOrphanRecorded handler can locate the on-disk path.
  """

  @enforce_keys [:operation_id, :project_id, :run_id, :phase_id]
  @type t :: %__MODULE__{
          operation_id: String.t(),
          project_id: String.t(),
          run_id: String.t(),
          phase_id: String.t(),
          repo_path: String.t() | nil,
          worktree_path: String.t() | nil,
          branch: String.t() | nil,
          base_ref: String.t() | nil,
          cleanup: String.t() | nil
        }
  @derive Jason.Encoder
  defstruct [
    :operation_id,
    :project_id,
    :run_id,
    :phase_id,
    :repo_path,
    :worktree_path,
    :branch,
    :base_ref,
    :cleanup
  ]
end
