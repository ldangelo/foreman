defmodule ForemanServer.Events.RunRepoRequested do
  @moduledoc """
  Typed audit event appended to `run_repo_audit:<run_id>` for EVERY request a
  thread makes to add a repository to its own run (`run.repo.request`),
  allowed or denied. A denied request changes nothing else; this event is the
  only trace.

  `requested_path` is what the thread asked for (the registered path when it
  named a `repo_id`), `repo_id` the registered repository when one was
  resolved (`nil` for a denied unregistered path), `decision` is `"allowed"` or
  `"denied"` and `reason` a short machine-readable code.
  """
  @enforce_keys [:run_id, :project_id, :requested_path, :decision, :reason, :requested_by, :at]
  @type t :: %__MODULE__{
          run_id: String.t(),
          project_id: String.t(),
          requested_path: String.t(),
          repo_id: String.t() | nil,
          decision: String.t(),
          reason: String.t(),
          requested_by: String.t(),
          at: String.t()
        }
  @derive Jason.Encoder
  defstruct [
    :run_id,
    :project_id,
    :requested_path,
    :repo_id,
    :decision,
    :reason,
    :requested_by,
    :at
  ]
end
