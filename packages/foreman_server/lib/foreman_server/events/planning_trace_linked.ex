defmodule ForemanServer.Events.PlanningTraceLinked do
  @enforce_keys [:flow_id]
  @type t :: %__MODULE__{
    flow_id: String.t()
  }
  @derive Jason.Encoder
  defstruct [:flow_id]
end
