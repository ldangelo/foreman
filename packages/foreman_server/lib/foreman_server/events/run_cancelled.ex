defmodule ForemanServer.Events.RunCancelled do
  @moduledoc "Typed event emitted when a run is cancelled via `run.cancel`."
  @enforce_keys [:run_id, :project_id]
  @type t :: %__MODULE__{
          run_id: String.t(),
          project_id: String.t(),
          reason: String.t() | nil,
          status: String.t() | nil,
          sequence: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [:run_id, :project_id, :reason, :status, :sequence]
end
