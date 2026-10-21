defmodule ForemanServer.Events.ThreadReopened do
  @moduledoc """
  Typed event appended to `thread:<thread_id>` when a resolved thread is
  reopened, returning it to the active group.
  """
  @enforce_keys [:thread_id, :project_id, :at]
  @type t :: %__MODULE__{
          thread_id: String.t(),
          project_id: String.t(),
          reopened_by: String.t() | nil,
          source: String.t() | nil,
          at: String.t()
        }
  @derive Jason.Encoder
  defstruct [:thread_id, :project_id, :reopened_by, :source, :at]
end
