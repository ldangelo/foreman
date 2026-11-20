defmodule ForemanServer.Events.RunFollowUpRequested do
  @moduledoc """
  Typed event appended to `run_followup:<run_id>` when automation asks for a
  FOLLOW-UP run (`run.followup.request`): a run that has no task of its own, is
  attached to an existing branch (a PR's head) and pushes to it, fast-forward
  only. The Dispatcher admits it through `RunAdmission.start/2` like any run.

  `kind` names the producer (`"pr_fix"`); `parent_run_id` is the run whose PR it
  works on; `attach_branch` is the branch the run's worktree is attached to and
  the only branch it may push; `resume_session_provider` / `resume_session_id`
  name a provider session the first phase resumes (both or neither); `note` is
  the operator's note. `prompt` is the already-redacted fix prompt; `provider`, `model`, `effort`,
  `approval_mode` and `sandbox` (`"docker"`) describe the agent the single phase runs. `repo_path` is the
  registered repository the PR lives in (absent: the project's primary); `worktree_path` is the
  original run's worktree path, where the session being resumed was keyed.

  Written ONLY while `config :foreman_server, :followup_runs` is on (default
  off), so a build without this struct can be rolled back to until the first
  one is recorded (docs/plans/retire-jobsites.md §7). Every key but the first
  five is optional and NOT enforced: a new key must never be added to
  `@enforce_keys`, or historical events stop decoding.
  """
  @enforce_keys [:run_id, :project_id, :kind, :requested_by, :at]
  @type t :: %__MODULE__{
          run_id: String.t(),
          project_id: String.t(),
          kind: String.t(),
          requested_by: String.t(),
          at: String.t(),
          parent_run_id: String.t() | nil,
          pr_url: String.t() | nil,
          fix_kind: String.t() | nil,
          attach_branch: String.t() | nil,
          push: boolean() | nil,
          resume_session_provider: String.t() | nil,
          resume_session_id: String.t() | nil,
          prompt: String.t() | nil,
          provider: String.t() | nil,
          model: String.t() | nil,
          effort: String.t() | nil,
          approval_mode: String.t() | nil,
          sandbox: String.t() | nil,
          repo_path: String.t() | nil,
          worktree_path: String.t() | nil,
          note: String.t() | nil
        }
  @derive Jason.Encoder
  defstruct [
    :run_id,
    :project_id,
    :kind,
    :requested_by,
    :at,
    :parent_run_id,
    :pr_url,
    :fix_kind,
    :attach_branch,
    :push,
    :resume_session_provider,
    :resume_session_id,
    :prompt,
    :provider,
    :model,
    :effort,
    :approval_mode,
    :sandbox,
    :repo_path,
    :worktree_path,
    :note
  ]
end
