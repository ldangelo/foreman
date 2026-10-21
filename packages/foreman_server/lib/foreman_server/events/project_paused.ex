defmodule ForemanServer.Events.ProjectPaused do
  @moduledoc """
  Typed event emitted when an operator pauses a project. A paused project
  refuses NEW admissions (task creation, run reservation, jobsite start,
  BeadsWatcher imports); in-flight runs and jobsites continue.
  """
  @enforce_keys [:project_id]
  @type t :: %__MODULE__{project_id: String.t(), reason: String.t() | nil}
  @derive Jason.Encoder
  defstruct [:project_id, :reason]
end
