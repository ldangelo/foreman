defmodule ForemanServer.Events.ProjectMemoryForgotten do
  @moduledoc """
  Typed event appended to `project_memory:<project_id>` when a memory topic is
  deleted. Metadata only; the topic file is removed from disk.
  """
  @enforce_keys [:project_id, :name, :author_kind, :at]
  @type t :: %__MODULE__{
          project_id: String.t(),
          name: String.t(),
          author_kind: String.t(),
          author_ref: String.t() | nil,
          at: String.t()
        }
  @derive Jason.Encoder
  defstruct [:project_id, :name, :author_kind, :author_ref, :at]
end
