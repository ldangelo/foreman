defmodule ForemanServer.Events.PrWatchStopped do
  @moduledoc """
  Typed event on `run:<run_id>`: Foreman stopped watching a PR (E9-S5).
  `reason` is `operator`, `merged` or `closed`. A stopped PR is excluded from
  polling and never auto-fixed until a `PrWatchStarted`.
  """
  @enforce_keys [:run_id, :project_id, :task_id, :pr_url, :reason]
  @type t :: %__MODULE__{
          run_id: String.t(),
          project_id: String.t(),
          task_id: String.t(),
          pr_url: String.t(),
          repo_id: String.t() | nil,
          reason: String.t(),
          stopped_by: String.t() | nil,
          stopped_at: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [:run_id, :project_id, :task_id, :pr_url, :repo_id, :reason, :stopped_by, :stopped_at]
end
