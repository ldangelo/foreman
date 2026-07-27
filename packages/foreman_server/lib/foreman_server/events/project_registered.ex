defmodule ForemanServer.Events.ProjectRegistered do
  @enforce_keys [:project_id, :path]
  @type t :: %__MODULE__{
    project_id: String.t(),
    path: String.t(),
    status: String.t() | nil,
    default_branch: String.t() | nil,
    config: map() | nil,
    health: map() | nil
  }
  @derive Jason.Encoder
  defstruct [:project_id, :path, :status, :default_branch, :config, :health]
end
