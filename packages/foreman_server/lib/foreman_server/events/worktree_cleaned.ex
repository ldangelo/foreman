defmodule ForemanServer.Events.WorktreeCleaned do
  @moduledoc """
  Emitted when Foreman removes a managed VCS worktree after a phase
  completes (success, failure, or terminal cancel). Carries the same
  deterministic correlation tuple as `WorktreeCreated` so projections and
  the orphan handler can correlate the cleanup with the prior create.
  """

  # `repo_id`: absent = the run's primary repo (E12); declared for strict decode.
  @enforce_keys [:operation_id, :project_id, :run_id, :phase_id]
  @type t :: %__MODULE__{
          operation_id: String.t(),
          project_id: String.t(),
          run_id: String.t(),
          phase_id: String.t(),
          repo_path: String.t() | nil,
          worktree_path: String.t() | nil,
          cleanup_observed: String.t() | nil,
          repo_id: String.t() | nil
        }
  @derive Jason.Encoder
  defstruct [
    :operation_id,
    :project_id,
    :run_id,
    :phase_id,
    :repo_path,
    :worktree_path,
    :cleanup_observed,
    :repo_id
  ]
end
