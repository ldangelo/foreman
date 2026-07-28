defmodule ForemanServer.Events.SchedulerTicked do
  @type t :: %__MODULE__{
    project_id: String.t() | nil
  }
  @derive Jason.Encoder
  defstruct [project_id: "global"]
end
