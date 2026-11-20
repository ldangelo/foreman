defmodule ForemanServer.Events.PrReportRequested do
  @moduledoc """
  TRD-030: an operator asked for the risk report of a PR to be published again. Emitted by the
  operator command `run.pr.publish_report` (CLI `foreman run publish-report`); no MCP tool,
  coordinator or approvals path carries it.

  `head_sha` and `digest` are never read from the request: the handler names the head and
  digest of the risk record the aggregate holds for the PR (`evidence.risk`), and refuses a
  request that carries either. `PrReport.Publisher` reacts to the event and publishes that
  record's report, the retry of a refused publication (`redaction_failed`, `effect_refused`,
  `gh_failed`, `publisher_error`). The event changes no folded state: its outcome is a
  `PrCommentPublished`.

  `requested_by` is the operator's own label when the request carried one (at most 128
  characters) and `requested_at` the request time in milliseconds.
  """
  @enforce_keys [:run_id, :project_id, :task_id, :pr_url, :head_sha, :digest, :requested_at]
  @type t :: %__MODULE__{
          run_id: String.t(),
          project_id: String.t(),
          task_id: String.t(),
          pr_url: String.t(),
          repo_id: String.t() | nil,
          head_sha: String.t(),
          digest: String.t(),
          requested_by: String.t() | nil,
          requested_at: non_neg_integer()
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
    :requested_by,
    :requested_at
  ]
end
