defmodule ForemanServer.Events.ProjectRepositoryRemoved do
  @moduledoc """
  Typed event emitted on the `project:<project_id>` stream when a non-primary
  repository is detached from a project (`project.repo.remove`). The primary
  repository (the project's `path`) is never removed by event.
  """
  @enforce_keys [:project_id, :repo_id, :removed_by, :at]
  @type t :: %__MODULE__{
          project_id: String.t(),
          repo_id: String.t(),
          removed_by: String.t(),
          at: String.t()
        }
  @derive Jason.Encoder
  defstruct [:project_id, :repo_id, :removed_by, :at]
end
