defmodule ForemanServer.Events.PrFixStarted do
  @moduledoc """
  Typed event on `run:<run_id>`: the follow-up jobsite for a requested PR fix
  was started (E9-S3). `jobsite_id` is the jobsite the reactor spawned; the
  aggregate records it as the one fix in flight for the PR.
  """
  @enforce_keys [:run_id, :project_id, :task_id, :pr_url, :kind, :attempt, :jobsite_id]
  @type t :: %__MODULE__{
          run_id: String.t(),
          project_id: String.t(),
          task_id: String.t(),
          pr_url: String.t(),
          repo_id: String.t() | nil,
          kind: String.t(),
          attempt: pos_integer(),
          jobsite_id: String.t(),
          head_sha: String.t() | nil,
          resumed_session: boolean(),
          started_at: non_neg_integer() | nil
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
    :jobsite_id,
    :head_sha,
    :started_at,
    resumed_session: false
  ]
end
