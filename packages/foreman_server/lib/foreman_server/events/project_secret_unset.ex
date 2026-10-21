defmodule ForemanServer.Events.ProjectSecretUnset do
  @moduledoc "A project secret was deleted. Name and version only; never a value."
  @enforce_keys [:project_id, :name, :version, :at]
  @type t :: %__MODULE__{
          project_id: String.t(),
          name: String.t(),
          version: pos_integer(),
          at: String.t(),
          author_ref: String.t() | nil
        }
  @derive Jason.Encoder
  defstruct [:project_id, :name, :version, :at, :author_ref]
end
