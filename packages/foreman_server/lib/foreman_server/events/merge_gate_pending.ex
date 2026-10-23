defmodule ForemanServer.Events.MergeGatePending do
  @moduledoc """
  TRD-071: MergeGatePending event — the run's PR is held at the merge gate and
  requires explicit human approval via `merge_approve` before `run.pr.merge` is
  accepted. It drops any approval the gate held.

  It is emitted by the `run.pr.rehold` system command when the PR head moved after the operator
  approved it: `reason` is `"head_moved_since_approval"`, `approved_head_sha` the head that had been
  approved (that approval is void and is never honoured again) and `head_sha` the head now
  observed. The operator must approve again with the new head. Those three fields are `nil` on a
  plain hold.
  """
  @enforce_keys [:run_id, :pr_url]
  @type t :: %__MODULE__{
          run_id: String.t(),
          pr_url: String.t(),
          pr_number: non_neg_integer() | nil,
          paused_at: non_neg_integer() | nil,
          repo_id: String.t() | nil,
          reason: String.t() | nil,
          approved_head_sha: String.t() | nil,
          head_sha: String.t() | nil
        }
  @derive Jason.Encoder
  # `repo_id` is present only for a non-primary repository's PR (E12).
  defstruct [
    :run_id,
    :pr_url,
    pr_number: nil,
    paused_at: nil,
    repo_id: nil,
    reason: nil,
    approved_head_sha: nil,
    head_sha: nil
  ]
end
