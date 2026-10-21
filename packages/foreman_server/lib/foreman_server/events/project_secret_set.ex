defmodule ForemanServer.Events.ProjectSecretSet do
  @moduledoc """
  A project secret was stored or rotated. Carries the secret's NAME and a
  monotonically increasing `version` only. By design there is no value, hash or
  fingerprint field: the value lives solely in `ForemanServer.SecretStore`.
  """
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
