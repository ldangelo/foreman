defmodule ForemanServer.Events.RunFailed do
  @moduledoc "Typed event emitted when a run has failed terminally."
  @enforce_keys [:run_id, :project_id, :sequence]
  @type t :: %__MODULE__{
          run_id: String.t(),
          project_id: String.t(),
          sequence: non_neg_integer(),
          reason: String.t() | nil
        }
  @derive Jason.Encoder
  defstruct [:run_id, :project_id, :sequence, :reason]
end
