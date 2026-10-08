defmodule ForemanServer.Events.JobsiteIterationStarted do
  @moduledoc "Typed event emitted when a jobsite iteration begins."
  @enforce_keys [:jobsite_id, :index]
  @type t :: %__MODULE__{
          jobsite_id: String.t(),
          index: pos_integer(),
          resumed_session_id: String.t() | nil,
          started_at_ms: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [:jobsite_id, :index, :resumed_session_id, :started_at_ms]
end
