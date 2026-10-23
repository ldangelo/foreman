defmodule ForemanServer.Events.MergeGateApproved do
  @moduledoc """
  TRD-071: MergeGateApproved event — emitted by the Run aggregate when
  the `merge_approve` command is dispatched after human authorization.
  Unblocks `run.pr.merge` for the associated run.

  `head_sha` is the PR head the operator approved: the commit they reviewed, read back from GitHub
  before the command was dispatched. The merge is pinned to exactly that commit, and the approval
  is void as soon as the PR head differs from it (`MergeGatePending` with
  `reason: "head_moved_since_approval"`). It is `nil` only on an approval recorded before heads were
  pinned; the aggregate then takes the head the PR watch had last recorded as the pin.
  """
  @enforce_keys [:run_id, :approver, :approver_identity]
  @type t :: %__MODULE__{
          run_id: String.t(),
          approver: String.t(),
          approver_identity: String.t(),
          head_sha: String.t() | nil,
          approved_at: non_neg_integer() | nil,
          repo_id: String.t() | nil
        }
  @derive Jason.Encoder
  # `repo_id` is present only for a non-primary repository's PR (E12).
  defstruct [
    :run_id,
    :approver,
    :approver_identity,
    head_sha: nil,
    approved_at: nil,
    repo_id: nil
  ]
end
