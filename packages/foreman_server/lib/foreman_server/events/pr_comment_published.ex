defmodule ForemanServer.Events.PrCommentPublished do
  @moduledoc """
  TRD-021: the outcome of publishing the report of one PR head and risk digest as a PR comment.
  Emitted by the system command `run.pr.comment_published`, which only `PrReport.Publisher`
  dispatches (no operator, MCP tool, coordinator or approvals path carries it).

  `head_sha` and `digest` name the `PrRiskRecorded` record the report was rendered from (the
  handler refuses an outcome for a record `evidence.risk` does not hold). `status` is
  `published` (the comment `comment_id`/`comment_url` carries the report; `superseded` is the
  head of the earlier report of this run that the comment replaced, or `nil` when it was
  created or adopted as it was) or `refused` (nothing was written; `reason` is
  `redaction_failed | effect_refused | gh_failed` and `detail`, redacted and at most 500
  characters, names the cause and never a secret value). `recorded_at` is the time of the
  attempt in milliseconds, so two refused attempts are two events.

  `PrEvidence` folds it into `evidence.report`, which keeps its own head across a head move.
  Posting the comment starts no automation, and the merge gate does not read it.
  """
  @enforce_keys [
    :run_id,
    :project_id,
    :task_id,
    :pr_url,
    :head_sha,
    :digest,
    :status,
    :recorded_at
  ]
  @type t :: %__MODULE__{
          run_id: String.t(),
          project_id: String.t(),
          task_id: String.t(),
          pr_url: String.t(),
          repo_id: String.t() | nil,
          head_sha: String.t(),
          digest: String.t(),
          status: String.t(),
          reason: String.t() | nil,
          detail: String.t() | nil,
          comment_id: pos_integer() | nil,
          comment_url: String.t() | nil,
          superseded: String.t() | nil,
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
    :digest,
    :status,
    :reason,
    :detail,
    :comment_id,
    :comment_url,
    :superseded,
    :recorded_at
  ]
end
