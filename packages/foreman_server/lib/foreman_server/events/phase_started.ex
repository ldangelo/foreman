defmodule ForemanServer.Events.PhaseStarted do
  @moduledoc """
  Typed event emitted when a workflow phase has started.

  `prior_worktree_discarded` is optional: it carries the record of uncommitted
  work lost when the run's worktree was re-provisioned on resume, on the first
  phase event after the resume when no phase was in flight.

  `input_artifacts` is optional: the artifact references the phase started from,
  `[%{index, source_phase, path, sha256}]`. Phase 1 carries `[]`; a stream
  recorded before the field existed carries none.
  """
  @enforce_keys [:phase_id, :run_id, :index, :name, :attempt, :artifact_template]
  @type t :: %__MODULE__{
          phase_id: String.t(),
          sequence: non_neg_integer() | nil,
          run_id: String.t(),
          index: pos_integer(),
          name: String.t(),
          attempt: pos_integer(),
          artifact_template: String.t(),
          stall_detection_kind: String.t() | nil,
          stall_threshold_ms: pos_integer() | nil,
          stall_policy: String.t() | nil,
          prior_worktree_discarded: %{name: String.t(), path: String.t() | nil} | nil,
          input_artifacts: [map()] | nil
        }
  @derive Jason.Encoder
  defstruct [
    :phase_id,
    :sequence,
    :run_id,
    :index,
    :name,
    :attempt,
    :artifact_template,
    :stall_detection_kind,
    :stall_threshold_ms,
    :stall_policy,
    :prior_worktree_discarded,
    :input_artifacts
  ]
end
