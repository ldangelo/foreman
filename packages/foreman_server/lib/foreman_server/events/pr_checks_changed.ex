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

  `checks` is every check of the head the observer read (at most 100, newest kept; each
  string-keyed `%{name, kind, state, conclusion, workflow, started_at, completed_at}`), or `nil`
  for an event written before it existed (replayed as no list recorded, never as zero checks);
  `required` (`nil` or at most 20 `%{name, kind}`) and `policy_version` are the policy's inputs
  (`nil` until a policy supplies them); `checks_truncated`
  says the PR has more, and `evidence_digest` is the digest of exactly that evidence (it moves
  when a passing check is added, removed or re-run; `digest` does not). `observation_ref` is
  `nil` for an observer reading and the nonce of a forced observation. `source` is `"watch"`
  for the observer and `"gate"` for a forced observation; only `"watch"` notifies (a gate
  observation must not notify), and an event without a `source` no longer maps.
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
          checks: [map()] | nil,
          checks_truncated: boolean(),
          evidence_digest: String.t() | nil,
          observation_ref: String.t() | nil,
          required: [map()] | nil,
          policy_version: String.t() | nil,
          source: String.t() | nil,
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
    :evidence_digest,
    :observation_ref,
    :source,
    :required,
    :policy_version,
    :checks,
    failing: [],
    checks_truncated: false,
    observation_seq: 0
  ]
end
