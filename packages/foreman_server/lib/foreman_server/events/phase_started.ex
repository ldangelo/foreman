defmodule ForemanServer.Events.PhaseStarted do
  @moduledoc "Typed event emitted when a workflow phase has started."
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
          stall_policy: String.t() | nil
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
    :stall_policy
  ]
end
