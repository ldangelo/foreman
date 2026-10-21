defmodule ForemanServer.Events.RunSteerQueued do
  @moduledoc """
  Typed event emitted when an operator queues a steering message for a run
  (`run.steer`, E6-S4).

  This event is the durable mailbox entry: pending steering for a run is
  `RunSteerQueued` minus `RunSteerConsumed`, reconstructed from the event
  log (and therefore the projection) after any restart. `RunControl`'s ETS
  mailbox is only a cache of it.

  ## Field contract

    * `run_id` - Run aggregate stream id component (enforced).
    * `message_id` - Caller-supplied idempotency key (enforced); queueing
      the same id twice emits one event.
    * `text` - Operator message, verbatim (enforced, at most 8000 chars).
    * `steered_by` - Actor identifier, nil when the caller names none.
    * `resume` - When `false` the run stays paused after the steer-pause
      until an operator resumes it; default `true` (auto-resume).
  """
  @enforce_keys [:run_id, :message_id, :text]
  @type t :: %__MODULE__{
          run_id: String.t(),
          message_id: String.t(),
          text: String.t(),
          steered_by: String.t() | nil,
          resume: boolean(),
          sequence: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [:run_id, :message_id, :text, :steered_by, :sequence, resume: true]
end
