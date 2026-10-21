defmodule ForemanServer.Events.CoordinatorRestarted do
  @moduledoc """
  Typed event: an operator restarted the coordinator, clearing its failure
  counters and any open turn so pending messages are processed again.
  """
  @enforce_keys [:project_id, :at]
  @type t :: %__MODULE__{project_id: String.t(), by: String.t() | nil, at: String.t()}
  @derive Jason.Encoder
  defstruct [:project_id, :by, :at]
end
