defmodule ForemanServer.Events.RunCompleted do
  @moduledoc "Typed event emitted when a run has completed successfully."
  @enforce_keys [:run_id, :project_id, :sequence]
  @type t :: %__MODULE__{
          run_id: String.t(),
          project_id: String.t(),
          sequence: non_neg_integer(),
          status: String.t() | nil
        }
  @derive Jason.Encoder
  defstruct [:run_id, :project_id, :sequence, :status]
end
