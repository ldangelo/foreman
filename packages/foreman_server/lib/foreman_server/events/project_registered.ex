defmodule ForemanServer.Events.ProjectRegistered do
  @moduledoc "Typed event emitted when a project is registered."
  @enforce_keys [:project_id, :path, :task_provider]
  @type t :: %__MODULE__{
          project_id: String.t(),
          path: String.t(),
          task_provider: map()
        }
  @derive Jason.Encoder
  defstruct [:project_id, :path, :task_provider]
end
