defmodule ForemanServer.Events.RunStallReported do
  @moduledoc "Durable event emitted when phase-level stall detection reports a run stall."
  @enforce_keys [
    :run_id,
    :phase_id,
    :stall_kind,
    :policy,
    :threshold_ms,
    :idle_ms,
    :detected_at_ms,
    :idempotency_key,
    :reason
  ]
  @type t :: %__MODULE__{
          run_id: String.t(),
          sequence: non_neg_integer() | nil,
          task_id: String.t() | nil,
          phase_id: String.t(),
          phase_index: non_neg_integer() | nil,
          phase_name: String.t() | nil,
          stall_kind: String.t(),
          policy: String.t(),
          status_effect: String.t() | nil,
          threshold_ms: pos_integer(),
          idle_ms: non_neg_integer(),
          activity_at_ms: non_neg_integer() | nil,
          detected_at_ms: non_neg_integer(),
          idempotency_key: String.t(),
          reason: String.t()
        }
  @derive Jason.Encoder
  defstruct [
    :run_id,
    :sequence,
    :task_id,
    :phase_id,
    :phase_index,
    :phase_name,
    :stall_kind,
    :policy,
    :status_effect,
    :threshold_ms,
    :idle_ms,
    :activity_at_ms,
    :detected_at_ms,
    :idempotency_key,
    :reason
  ]
end
