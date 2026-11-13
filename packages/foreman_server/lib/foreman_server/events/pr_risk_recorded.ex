defmodule ForemanServer.Events.PrRiskRecorded do
  @moduledoc """
  TRD-018: the risk of one PR head, classified by `ForemanServer.PrRisk.Rubric` over the
  inputs the system held when it was recorded. Emitted by the system command `run.pr.risk`
  (`PrObservation` builds it for every observed PR; no operator and no agent writes it).

  `head_sha` is the head the record is about; the level is never read by anything that does
  not also compare that head with the head being decided. `level` is `LOW | MEDIUM | HIGH`
  and `rubric_version` names the rules that produced it. `rationale` is the rubric's list of
  `%{rule, level, basis, detail}` (`basis` is `machine` or `agent_claim`); `evidence` is a
  summary of every input (checks status and reason codes, findings status, defect and counts
  by severity, judgement status and level, changed files, additions and deletions, whether the
  path list was incomplete, the sensitive hits, the PR base and the recorded base,
  `policy_version`); `unresolved_findings` lists the open findings, bounded; `instructions` is
  the rubric's fixed reviewer text; `judgement` is the review agent's judgement as the rubric
  saw it (`status`, `level`, `defect`, `head_sha`; never its free text). `findings_digest` is
  the `digest` of the `evidence.findings` record the level was computed from (`nil` when there
  was none). `digest` is derived by the handler from every other content field and the
  identity, never read from a payload; `seq` is the previous record's plus one; `recorded_at`
  is the observation time in milliseconds.

  `PrEvidence` folds it into `evidence.risk`, which keeps ITS OWN `head_sha` across a head
  change: readers compare it with the head being decided. All nested maps are string-keyed so
  the live and the replayed event are one value.
  """
  @enforce_keys [
    :run_id,
    :project_id,
    :task_id,
    :pr_url,
    :head_sha,
    :level,
    :rubric_version,
    :digest,
    :seq,
    :recorded_at
  ]
  @type t :: %__MODULE__{
          run_id: String.t(),
          project_id: String.t(),
          task_id: String.t(),
          pr_url: String.t(),
          repo_id: String.t() | nil,
          head_sha: String.t(),
          level: String.t(),
          rubric_version: String.t(),
          rationale: [map()],
          evidence: map(),
          unresolved_findings: [map()],
          instructions: [String.t()],
          judgement: map() | nil,
          findings_digest: String.t() | nil,
          digest: String.t(),
          seq: pos_integer(),
          recorded_at: non_neg_integer()
        }
  @derive Jason.Encoder
  defstruct [
    :run_id,
    :project_id,
    :task_id,
    :pr_url,
    :repo_id,
    :head_sha,
    :level,
    :rubric_version,
    :judgement,
    :findings_digest,
    :digest,
    :seq,
    :recorded_at,
    rationale: [],
    evidence: %{},
    unresolved_findings: [],
    instructions: []
  ]
end
