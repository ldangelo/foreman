defmodule ForemanServer.Events.RunBlocked do
  @moduledoc "Typed event emitted when a run is blocked terminally."
  @enforce_keys [:run_id, :project_id]
  @type t :: %__MODULE__{
          run_id: String.t(),
          project_id: String.t(),
          sequence: non_neg_integer() | nil,
          reason: String.t() | nil,
          status: String.t() | nil
        }
  @derive Jason.Encoder
  defstruct [:run_id, :project_id, :sequence, :reason, :status]
end
