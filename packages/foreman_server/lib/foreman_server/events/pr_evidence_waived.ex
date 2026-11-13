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
          repo_id: String.t() | nil
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
    repo_id: nil
  ]
end
