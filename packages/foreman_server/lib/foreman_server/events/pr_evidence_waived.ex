defmodule ForemanServer.Events.PrEvidenceWaived do
  @moduledoc """
  TRD-012: an operator waived the missing or skipped evidence of one PR for one head. Emitted
  by the `Run` aggregate for the operator-only command `run.pr.waive_evidence`, beside
  `merge_approve`.

  `pr_url` is the PR the repository's merge gate holds (never a caller's value) and `head_sha`
  the head the operator reviewed, which the gateway read back from GitHub. `reasons` are the
  waived reason codes (sorted, de-duplicated; only the waivable set of §11) and `reason` the
  operator's text. `policy_version` is the version of the project's `required_checks` when the
  waiver was given, stamped by the gateway: the evaluator applies the waiver only while the
  policy still has it. `waived_at` is a millisecond timestamp; `repo_id` is present only for a
  non-primary repository's PR. `PrEvidence` folds it into `evidence.waiver` for that head, and a
  later head change voids it.

  `risk_digest` is the digest of the risk record of that head when the waiver names `risk_high`
  (`nil` when the PR held no such record), and is absent from every other waiver: a `risk_high`
  waiver covers that risk record only, so a risk record that read differently later (the PR's base
  moved, a new findings record) is not covered by it. It is optional and never an enforced key, so
  every waiver recorded before it existed still decodes.
  """
  @enforce_keys [
    :run_id,
    :pr_url,
    :head_sha,
    :approver,
    :approver_identity,
    :reasons,
    :reason,
    :policy_version,
    :waived_at
  ]
  @type t :: %__MODULE__{
          run_id: String.t(),
          pr_url: String.t(),
          head_sha: String.t(),
          approver: String.t(),
          approver_identity: String.t(),
          reasons: [String.t()],
          reason: String.t(),
          policy_version: String.t(),
          waived_at: non_neg_integer(),
          repo_id: String.t() | nil,
          risk_digest: String.t() | nil
        }
  @derive Jason.Encoder
  defstruct [
    :run_id,
    :pr_url,
    :head_sha,
    :approver,
    :approver_identity,
    :reasons,
    :reason,
    :policy_version,
    :waived_at,
    repo_id: nil,
    risk_digest: nil
  ]
end
