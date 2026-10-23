defmodule ForemanServer.Events.RunSteerDelivered do
  @moduledoc """
  Typed event emitted (system command `run.steer.deliver`) when a pending
  steering message was written into the running phase's LIVE provider session
  (mid-phase steering) instead of waiting for a phase boundary.

  Delivered is not consumed: the provider queues the message and takes it at its
  next safe point (after the in-flight tool call). The message stays pending
  until `RunSteerConsumed` (the agent took it) or `RunSteerUndelivered` (the run
  ended first).

    * `run_id`, `message_id` - the `RunSteerQueued` being delivered (enforced).
    * `mode` - `"live"`.
  """
  @enforce_keys [:run_id, :message_id, :mode]
  @type t :: %__MODULE__{
          run_id: String.t(),
          message_id: String.t(),
          mode: String.t(),
          sequence: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [:run_id, :message_id, :mode, :sequence]
end
