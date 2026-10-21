defmodule ForemanServer.Events.ProjectResumed do
  @moduledoc "Typed event emitted when a paused project is resumed."
  @enforce_keys [:project_id]
  @type t :: %__MODULE__{project_id: String.t()}
  @derive Jason.Encoder
  defstruct [:project_id]
end
