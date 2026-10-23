defmodule ForemanServer.Events.RunSteerConsumed do
  @moduledoc """
  Typed event emitted (system command `run.steer.consume`) once a phase
  prompt carrying the listed steering messages was built successfully, so a
  later resume does not inject them again (E6-S4).

  `message_ids` lists the `RunSteerQueued.message_id`s that were injected.
  `delivery` is `"prompt"` (built into the next phase prompt) or `"live"` (the
  agent took it inside its running session); absent on historical events = prompt.
  """
  @enforce_keys [:run_id, :message_ids]
  @type t :: %__MODULE__{
          run_id: String.t(),
          message_ids: [String.t()],
          delivery: String.t() | nil,
          sequence: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [:run_id, :message_ids, :delivery, :sequence]
end
