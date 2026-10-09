defmodule ForemanServer.Events.JobsiteCancelled do
  @moduledoc "Typed event emitted when a jobsite run is cancelled."
  @enforce_keys [:jobsite_id, :reason]
  @type t :: %__MODULE__{jobsite_id: String.t(), reason: String.t()}
  @derive Jason.Encoder
  defstruct [:jobsite_id, :reason]
end
