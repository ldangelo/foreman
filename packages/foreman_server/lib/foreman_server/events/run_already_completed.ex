defmodule ForemanServer.Events.RunAlreadyCompleted do
  @moduledoc "Typed event emitted when a `run.complete` is dispatched on a terminal run. State is unchanged — the command is idempotent."
  @enforce_keys [:run_id]
  @type t :: %__MODULE__{
          run_id: String.t(),
          status: String.t() | nil,
          sequence: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [:run_id, :status, :sequence]
end
