defmodule ForemanServer.Events.PhaseRetried do
  @moduledoc """
  Typed event emitted when a workflow phase is retried.

  `reason: "resumed"` marks a retry recorded when a restarted executor resumes a
  phase that was still `in_progress`; the phase stays `in_progress` and `attempt`
  advances. Any other reason keeps the phase in `retrying`.

  `prior_worktree_discarded` is optional: it carries the record of uncommitted
  work lost when a worktree was recreated before the retry.

  `input_artifacts` is optional: the artifact references the retried phase
  reads, `[%{index, source_phase, path, sha256}]` (see `PhaseStarted`).
  """
  @enforce_keys [:phase_id, :run_id, :index, :attempt, :reason]
  @type t :: %__MODULE__{
          phase_id: String.t(),
          sequence: non_neg_integer() | nil,
          run_id: String.t(),
          index: pos_integer(),
          attempt: pos_integer(),
          reason: String.t(),
          prior_worktree_discarded: %{name: String.t(), path: String.t() | nil} | nil,
          input_artifacts: [map()] | nil
        }
  @derive Jason.Encoder
  defstruct [
    :phase_id,
    :sequence,
    :run_id,
    :index,
    :attempt,
    :reason,
    :prior_worktree_discarded,
    :input_artifacts
  ]
end
