defmodule ForemanServer.Events.WorktreeCreateOrphanResolved do
  @moduledoc """
  Durable marker that a `WorktreeCreateOrphanRecorded` has been recovered.

  The orphan record is resolved when the on-disk worktree has been
  successfully removed (or was already absent) and the projection can
  drop the durable record. Required correlation tuple mirrors the
  recorded event so the projection key remains stable.

  Required correlation tuple: `operation_id`, `project_id`, `run_id`,
  `phase_id`. `worktree_path` and `repo_path` are echoed so the
  projection can validate key consistency during replay.
  """

  @enforce_keys [:operation_id, :project_id, :run_id, :phase_id]
  @type t :: %__MODULE__{
          operation_id: String.t(),
          project_id: String.t(),
          run_id: String.t(),
          phase_id: String.t(),
          worktree_path: String.t() | nil,
          repo_path: String.t() | nil,
          resolution: String.t() | nil
        }
  @derive Jason.Encoder
  defstruct [
    :operation_id,
    :project_id,
    :run_id,
    :phase_id,
    :worktree_path,
    :repo_path,
    :resolution
  ]
end
