defmodule ForemanServer.Events.PrFixRequested do
  @moduledoc """
  Typed event on `run:<run_id>`: a fix thread was requested for a watched PR
  (E9-S3). `kind` is `ci`, `comments` or `conflicts`; `attempt` is the
  aggregate's authoritative per-PR, per-kind counter after this request;
  `trigger` is `operator` or `auto`. The reactor in `ForemanServer.PrWatcher`
  reacts to this event and starts the follow-up jobsite.
  """
  @enforce_keys [:run_id, :project_id, :task_id, :pr_url, :kind, :attempt, :trigger, :head_sha]
  @type t :: %__MODULE__{
          run_id: String.t(),
          project_id: String.t(),
          task_id: String.t(),
          pr_url: String.t(),
          repo_id: String.t() | nil,
          kind: String.t(),
          attempt: pos_integer(),
          trigger: String.t(),
          head_sha: String.t(),
          requested_by: String.t() | nil,
          note: String.t() | nil,
          requested_at: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [
    :run_id,
    :project_id,
    :task_id,
    :pr_url,
    :repo_id,
    :kind,
    :attempt,
    :trigger,
    :head_sha,
    :requested_by,
    :note,
    :requested_at
  ]
end
