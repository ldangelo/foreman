defmodule ForemanServer.Events.ProjectLibraryRemoved do
  @moduledoc """
  Typed event appended to `project_library:<project_id>` when a library entry
  is removed. The files are deleted from disk by the facade; the event only
  records which entry went away and who removed it.
  """
  @enforce_keys [:project_id, :entry_id, :name, :author_kind, :at]
  @type t :: %__MODULE__{
          project_id: String.t(),
          entry_id: String.t(),
          name: String.t(),
          author_kind: String.t(),
          author_ref: String.t() | nil,
          at: String.t()
        }
  @derive Jason.Encoder
  defstruct [:project_id, :entry_id, :name, :author_kind, :author_ref, :at]
end
