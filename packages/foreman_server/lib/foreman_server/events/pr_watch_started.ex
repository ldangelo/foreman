defmodule ForemanServer.Events.PrWatchStarted do
  @moduledoc """
  Typed event on `run:<run_id>`: Foreman resumed watching a PR (E9-S5), either
  because the operator asked (`operator`) or because a closed PR was reopened
  (`reopened`).
  """
  @enforce_keys [:run_id, :project_id, :task_id, :pr_url, :reason]
  @type t :: %__MODULE__{
          run_id: String.t(),
          project_id: String.t(),
          task_id: String.t(),
          pr_url: String.t(),
          repo_id: String.t() | nil,
          reason: String.t(),
          started_by: String.t() | nil,
          started_at: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [:run_id, :project_id, :task_id, :pr_url, :repo_id, :reason, :started_by, :started_at]
end
