defmodule ForemanServer.Events.RunSteerUndelivered do
  @moduledoc """
  Typed event emitted (system command `run.steer.undeliver`) when steering
  messages were never taken by the agent and never will be: the run went
  terminal while they were still pending (queued, or delivered to a live
  session that ended before consuming them). Makes the loss visible instead of
  leaving the messages pending forever (foreman-b3jtt).

    * `run_id`, `message_ids` - the `RunSteerQueued` ids that were lost (enforced).
    * `reason` - why, e.g. `"run_completed"` / `"run_failed"` (enforced).
  """
  @enforce_keys [:run_id, :message_ids, :reason]
  @type t :: %__MODULE__{
          run_id: String.t(),
          message_ids: [String.t()],
          reason: String.t(),
          sequence: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [:run_id, :message_ids, :reason, :sequence]
end
