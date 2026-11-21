defmodule ForemanServer.Events.PrReadyFailed do
  @moduledoc """
  TRD-033: the `run.pr.ready` signal for a PR that exists could not be delivered, so the PR
  never reached the merge gate. Emitted by the system command `run.pr.ready_failed`, which
  `ForemanServer.PrReadySignal` dispatches when GitHub cannot be read (`stage: "head_read"`)
  or `run.pr.ready` is refused (`stage: "ready_dispatch"`).

  `pr_url` plus a nullable `repo_id` (absent = the run's primary repository) name the PR.
  `reason` is the head atom of the error, with the exit code for a `gh` failure
  (`gh_failed:1`); it never carries `gh` output, which stays in the log line. `failed_at` is
  the millisecond timestamp of the attempt. `PrEvidence` folds it into
  `evidence.delivery_issue`; the next `PrReady` for the PR clears it.
  """
  @enforce_keys [:run_id, :project_id, :task_id, :pr_url, :stage, :reason, :failed_at]
  @type t :: %__MODULE__{
          run_id: String.t(),
          project_id: String.t(),
          task_id: String.t(),
          pr_url: String.t(),
          repo_id: String.t() | nil,
          stage: String.t(),
          reason: String.t(),
          failed_at: non_neg_integer()
        }
  @derive Jason.Encoder
  defstruct [:run_id, :project_id, :task_id, :pr_url, :repo_id, :stage, :reason, :failed_at]
end
