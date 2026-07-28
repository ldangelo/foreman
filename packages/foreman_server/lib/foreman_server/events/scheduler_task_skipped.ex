defmodule ForemanServer.Events.SchedulerTaskSkipped do
  @enforce_keys [:task_id]
  @type t :: %__MODULE__{
    task_id: String.t(),
    project_id: String.t() | nil
  }
  @derive Jason.Encoder
  defstruct [
    :task_id,
    project_id: "global"
  ]
end
