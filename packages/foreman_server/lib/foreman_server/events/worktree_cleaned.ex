defmodule ForemanServer.Events.WorktreeCleaned do
  @moduledoc """
  Emitted when Foreman removes a managed VCS worktree after a phase
  completes (success, failure, or terminal cancel). Carries the same
  deterministic correlation tuple as `WorktreeCreated` so projections and
  the orphan handler can correlate the cleanup with the prior create.
  """

  @enforce_keys [:operation_id, :project_id, :run_id, :phase_id]
  @type t :: %__MODULE__{
          operation_id: String.t(),
          project_id: String.t(),
          run_id: String.t(),
          phase_id: String.t(),
          worktree_path: String.t() | nil,
          cleanup_observed: String.t() | nil
        }
  @derive Jason.Encoder
  defstruct [
    :operation_id,
    :project_id,
    :run_id,
    :phase_id,
    :worktree_path,
    :cleanup_observed
  ]
end
