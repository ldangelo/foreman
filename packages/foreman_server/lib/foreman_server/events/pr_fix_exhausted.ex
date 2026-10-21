defmodule ForemanServer.Events.PrFixExhausted do
  @moduledoc """
  Typed event on `run:<run_id>`: automatic fixing of one kind gave up for the
  PR at `head_sha` (E9-S4). `reason` is `max_attempts` or `no_progress`. This
  is the visible "auto-fix gave up" fact; it is cleared by a new commit on the
  PR head (a different `head_sha`).
  """
  @enforce_keys [:run_id, :project_id, :task_id, :pr_url, :kind, :reason, :head_sha]
  @type t :: %__MODULE__{
          run_id: String.t(),
          project_id: String.t(),
          task_id: String.t(),
          pr_url: String.t(),
          repo_id: String.t() | nil,
          kind: String.t(),
          reason: String.t(),
          attempts: non_neg_integer(),
          head_sha: String.t(),
          exhausted_at: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [
    :run_id,
    :project_id,
    :task_id,
    :pr_url,
    :repo_id,
    :kind,
    :reason,
    :head_sha,
    :exhausted_at,
    attempts: 0
  ]
end
