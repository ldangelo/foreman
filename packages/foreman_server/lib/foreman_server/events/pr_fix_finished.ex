defmodule ForemanServer.Events.PrFixFinished do
  @moduledoc """
  Typed event on `run:<run_id>`: a PR fix attempt ended (E9-S3). `outcome` is
  `pushed` (the PR head moved), `no_change` (the jobsite completed without a
  new head) or `failed` (the jobsite failed or could not be started;
  `error_code` says why). Clears the in-flight marker and records the head SHA
  the next attempt must beat.
  """
  @enforce_keys [:run_id, :project_id, :task_id, :pr_url, :kind, :attempt, :outcome]
  @type t :: %__MODULE__{
          run_id: String.t(),
          project_id: String.t(),
          task_id: String.t(),
          pr_url: String.t(),
          repo_id: String.t() | nil,
          kind: String.t(),
          attempt: pos_integer(),
          outcome: String.t(),
          jobsite_id: String.t() | nil,
          new_head_sha: String.t() | nil,
          error_code: String.t() | nil,
          finished_at: non_neg_integer() | nil
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
    :outcome,
    :jobsite_id,
    :new_head_sha,
    :error_code,
    :finished_at
  ]
end
