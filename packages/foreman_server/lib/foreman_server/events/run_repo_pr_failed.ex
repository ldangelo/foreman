defmodule ForemanServer.Events.RunRepoPrFailed do
  @moduledoc """
  E12-S6: one repository's pull request could not be created when the run
  finalised (push or `gh pr create` failed). The run still completes; the
  repository reads `pr_state: :create_failed` until `run.pr.retry` opens its PR.

  `repo_id` is always the repository's real id (the primary's included), because
  the operator addresses the retry by it. `reason` is the rendered failure.
  """
  @enforce_keys [:run_id, :repo_id, :reason, :at]
  @type t :: %__MODULE__{
          run_id: String.t(),
          repo_id: String.t(),
          reason: String.t(),
          at: non_neg_integer()
        }
  @derive Jason.Encoder
  defstruct [:run_id, :repo_id, :reason, :at]
end
