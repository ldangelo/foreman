defmodule ForemanServer.Events.ProjectUpdated do
  @enforce_keys [:project_id]
  @type t :: %__MODULE__{
    project_id: String.t(),
    name: String.t() | nil,
    status: String.t() | nil,
    default_branch: String.t() | nil,
    config: map() | nil,
    health: map() | nil
  }
  @derive Jason.Encoder
  defstruct [:project_id, :name, :status, :default_branch, :config, :health]
end
