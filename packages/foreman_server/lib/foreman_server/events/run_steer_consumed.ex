defmodule ForemanServer.Events.RunSteerConsumed do
  @moduledoc """
  Typed event emitted (system command `run.steer.consume`) once a phase
  prompt carrying the listed steering messages was built successfully, so a
  later resume does not inject them again (E6-S4).

  `message_ids` lists the `RunSteerQueued.message_id`s that were injected.
  """
  @enforce_keys [:run_id, :message_ids]
  @type t :: %__MODULE__{
          run_id: String.t(),
          message_ids: [String.t()],
          sequence: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [:run_id, :message_ids, :sequence]
end
