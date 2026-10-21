defmodule ForemanServer.Events.ProjectRepositoryAdded do
  @moduledoc """
  Typed event emitted on the `project:<project_id>` stream when a non-primary
  repository is attached to a project (`project.repo.add`).

  The primary repository is never added by event: it is always the project's
  `path`. `path` is the canonical (realpath) checkout path validated by the
  command gateway before dispatch. `default_branch` nil means "the branch
  checked out at run start" and is NEVER defaulted to `"main"`. `added_by` is
  `"operator:<id>"` or `"run:<run_id>"`; `at` is an ISO-8601 UTC timestamp.
  `task_provider` is reserved and always nil in v1.

  Keys of stored events must be declared fields here: `EventCodec` rejects
  unknown keys on decode.
  """
  @enforce_keys [:project_id, :repo_id, :path, :added_by, :at]
  @type t :: %__MODULE__{
          project_id: String.t(),
          repo_id: String.t(),
          path: String.t(),
          default_branch: String.t() | nil,
          vcs: map(),
          task_provider: nil,
          added_by: String.t(),
          at: String.t()
        }
  @derive Jason.Encoder
  defstruct [
    :project_id,
    :repo_id,
    :path,
    :default_branch,
    :task_provider,
    :added_by,
    :at,
    vcs: %{adapter: "git"}
  ]
end
