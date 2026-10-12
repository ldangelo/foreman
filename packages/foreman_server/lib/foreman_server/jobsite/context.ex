defmodule ForemanServer.Jobsite.Context do
  @moduledoc """
  Mutable (threaded, never mutated in place) state `ForemanServer.Jobsite.Engine`
  carries from step to step: what's been provisioned so far, the running
  iteration history, and whatever an `ForemanServer.Jobsite.Observer` chose to
  record (e.g. `artifact_path`).

  `vars` is open, nested data (plan-context-style key/value pairs an
  observer or a later step's prompt substitution wants) — the one field
  here that is legitimately a map rather than a named field, per §5.1.
  """

  alias ForemanServer.Jobsite.Worktree

  @enforce_keys [:jobsite_id, :repo_path]
  @type t :: %__MODULE__{
          jobsite_id: String.t(),
          repo_path: String.t(),
          worktree: Worktree.t() | nil,
          sandbox: term() | nil,
          iterations: [ForemanServer.Jobsite.IterationResult.t()],
          session_id: String.t() | nil,
          commits: [ForemanServer.Jobsite.Result.commit()],
          output: term() | nil,
          artifact_path: String.t() | nil,
          merged?: boolean(),
          preserved_path: String.t() | nil,
          vars: map()
        }
  defstruct [
    :jobsite_id,
    :repo_path,
    worktree: nil,
    sandbox: nil,
    iterations: [],
    session_id: nil,
    commits: [],
    output: nil,
    artifact_path: nil,
    merged?: false,
    preserved_path: nil,
    vars: %{}
  ]
end
