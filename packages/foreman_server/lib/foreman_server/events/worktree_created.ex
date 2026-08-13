defmodule ForemanServer.Events.WorktreeCreated do
  @moduledoc """
  Emitted when Foreman creates a managed VCS worktree for a phase.

  The correlation tuple (`operation_id`, `project_id`, `run_id`, `phase_id`)
  is the deterministic identifier for the worktree. `operation_id` is
  `"wt-" <> run_id <> "-" <> phase_id`; it is NOT a fresh UUID per attempt.
  Replaying a re-attempted create re-emits the same `operation_id` and finds
  the same projection slot.

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
    :worktree_path,
    :branch,
    :base_ref,
    :cleanup
  ]
end
