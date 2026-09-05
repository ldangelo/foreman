defmodule ForemanServer.Events.ProjectUpdated do
  @moduledoc "Typed event emitted when a project is updated."
  @enforce_keys [:project_id, :task_provider]
  @type t :: %__MODULE__{
          project_id: String.t(),
          task_provider: map() | nil,
          config: map()
        }
  @derive Jason.Encoder
  defstruct [:project_id, :task_provider, config: %{}]
end
