defmodule ForemanServer.ProjectMemory.SyncReport do
  @moduledoc "Outcome of `ProjectMemory.sync/2`: topics recorded, forgotten, and any that failed."
  alias ForemanServer.ProjectMemory.Error

  @type t :: %__MODULE__{
          recorded: [String.t()],
          forgotten: [String.t()],
          failed: [{String.t(), Error.t()}]
        }
  defstruct recorded: [], forgotten: [], failed: []
end
