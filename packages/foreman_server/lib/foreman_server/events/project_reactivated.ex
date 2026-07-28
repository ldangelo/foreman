defmodule ForemanServer.Events.ProjectReactivated do
  @enforce_keys [:project_id]
  @type t :: %__MODULE__{
    project_id: String.t()
  }
  @derive Jason.Encoder
  defstruct [:project_id]
end
