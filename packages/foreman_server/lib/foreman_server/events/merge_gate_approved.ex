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

  `evidence` (TRD-036) is the decision the approval was made on, as `PrEvidence.evaluate/2`
  answered it for this approval, never a reference to the live record: `status` (`"off"`,
  `"eligible"` or `"waived"`), `policy_version`, `required` (the policy's entries, `nil` for a
  gate that was off), `checks_ref`, `now_ms`, `waived` (the codes a waiver covered) and `inputs`
  (the eight keys `checks_head_sha`, `checks_observed_at`, `evidence_digest`, `checks_ref`,
  `findings_head_sha`, `findings_digest`, `risk_head_sha`, `risk_digest`; each `nil` when the PR
  held no such record). It is `nil` on an approval recorded before the gate read evidence.

  `gate_off_acknowledged` is `true` when the operator approved a project whose merge gate was off
  (no `required_checks`) and said so explicitly (`acknowledge_gate_off`, AC-001-3). It is written
  only when true and is `nil` otherwise, so every approval recorded before it existed, and every
  approval of a gated project, decodes and replays without it.
  """
  @enforce_keys [:run_id, :approver, :approver_identity]
  @type t :: %__MODULE__{
          run_id: String.t(),
          approver: String.t(),
          approver_identity: String.t(),
          head_sha: String.t() | nil,
          approved_at: non_neg_integer() | nil,
          repo_id: String.t() | nil,
          evidence: map() | nil,
          gate_off_acknowledged: boolean() | nil
        }
  @derive Jason.Encoder
  # `repo_id` is present only for a non-primary repository's PR (E12).
  defstruct [
    :run_id,
    :approver,
    :approver_identity,
    head_sha: nil,
    approved_at: nil,
    repo_id: nil,
    evidence: nil,
    gate_off_acknowledged: nil
  ]
end
