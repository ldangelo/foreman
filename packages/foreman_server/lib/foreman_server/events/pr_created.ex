defmodule ForemanServer.Events.PrCreated do
  @moduledoc """
  Typed event on `run:<run_id>`: the operator asked Foreman to open the PR for
  a run whose branch was pushed but never proposed (E9-S5, `run.pr.create`).
  The PR itself is opened by `ForemanServer.PrCreate` before dispatch and the
  association (`PrAssociated`) is recorded separately; this event is the
  audit fact on the run stream.
  """
  @enforce_keys [:run_id, :project_id, :task_id, :pr_url, :head_branch, :base_branch]
  @type t :: %__MODULE__{
          run_id: String.t(),
          project_id: String.t(),
          task_id: String.t(),
          pr_url: String.t(),
          head_branch: String.t(),
          base_branch: String.t(),
          created_by: String.t() | nil,
          created_at: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [
    :run_id,
    :project_id,
    :task_id,
    :pr_url,
    :head_branch,
    :base_branch,
    :created_by,
    :created_at
  ]
end
