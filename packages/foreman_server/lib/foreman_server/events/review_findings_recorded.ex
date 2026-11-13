defmodule ForemanServer.Events.ReviewFindingsRecorded do
  @moduledoc """
  TRD-015: the review findings of a run, recorded against the head they were produced for.
  Emitted by the system command `run.pr.findings` (the finalising executor, TRD-034) for the
  primary PR; a record belongs to one `pr_url` and, for a PR of another repository, carries
  that `repo_id`.

  `head_sha` is the locally resolved reviewed head (not a GitHub observation). `status` is
  `recorded` (a valid typed block, `findings` a list of string-keyed finding maps with
  `severity`, `path`, `line`, `description`, `disposition` and `source`), `absent` (no block:
  never a clean review) or `malformed` (`defect` one of TRD-013's parse reasons or
  `unreadable`, `defect_detail` the text for the operator); `findings` is empty for the
  last two. `artifact_path` and `artifact_sha256` name the artifact that was read. `digest` is
  derived by the handler from the normalised `status`, `defect` and `findings`, never read from
  a payload. `recorded_at` is a millisecond timestamp supplied by the caller.

  `PrEvidence` folds it into `evidence.findings`, which keeps ITS OWN `head_sha` across a head
  change: readers compare it with the head being decided.
  """
  @enforce_keys [
    :run_id,
    :project_id,
    :task_id,
    :pr_url,
    :head_sha,
    :status,
    :digest,
    :recorded_at
  ]
  @type t :: %__MODULE__{
          run_id: String.t(),
          project_id: String.t(),
          task_id: String.t(),
          pr_url: String.t(),
          repo_id: String.t() | nil,
          head_sha: String.t(),
          status: String.t(),
          findings: [map()],
          defect: String.t() | nil,
          defect_detail: String.t() | nil,
          artifact_path: String.t() | nil,
          artifact_sha256: String.t() | nil,
          digest: String.t(),
          recorded_at: non_neg_integer()
        }
  @derive Jason.Encoder
  defstruct [
    :run_id,
    :project_id,
    :task_id,
    :pr_url,
    :head_sha,
    :status,
    :digest,
    :recorded_at,
    repo_id: nil,
    findings: [],
    defect: nil,
    defect_detail: nil,
    artifact_path: nil,
    artifact_sha256: nil
  ]
end
