defmodule ForemanServer.Events.JobsiteWorktreeReleased do
  @moduledoc "Typed event emitted when a jobsite's worktree has been closed."
  @enforce_keys [:jobsite_id]
  @type t :: %__MODULE__{
          jobsite_id: String.t(),
          merged?: boolean() | nil,
          preserved_path: String.t() | nil
        }
  @derive Jason.Encoder
  defstruct [:jobsite_id, :merged?, :preserved_path]
end
