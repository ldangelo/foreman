defmodule ForemanServer.Events.PrChecksChanged do
  @moduledoc """
  Typed event on `run:<run_id>` recording that the CI checks of a watched PR
  changed (spike S4, E9-S1). Emitted by `ForemanServer.PrWatcher` through the
  `run.pr.checks` system command, once per distinct observation: `digest` is
  the content hash of (head SHA, checks state, failing check names), and
  `observation_seq` makes an A -> B -> A flip three distinct events.

  `pr_url` plus a nullable `repo_id` (absent = the run's primary repo, spike
  S3) identify the PR. `failing` lists the failing checks
  (`%{name, conclusion, url}`), bounded by the observer.
  """
  @enforce_keys [:run_id, :project_id, :task_id, :pr_url, :head_sha, :checks_state, :digest]
  @type t :: %__MODULE__{
          run_id: String.t(),
          project_id: String.t(),
          task_id: String.t(),
          pr_url: String.t(),
          repo_id: String.t() | nil,
          head_sha: String.t(),
          branch_name: String.t() | nil,
          base_branch: String.t() | nil,
          pr_status: String.t() | nil,
          checks_state: String.t(),
          failing: [map()],
          digest: String.t(),
          observation_seq: non_neg_integer(),
          observed_at: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [
    :run_id,
    :project_id,
    :task_id,
    :pr_url,
    :repo_id,
    :head_sha,
    :branch_name,
    :base_branch,
    :pr_status,
    :checks_state,
    :digest,
    :observed_at,
    failing: [],
    observation_seq: 0
  ]
end
