defmodule ForemanServer.Events.RunWorktreeRetained do
  @moduledoc """
  A run's worktree was NOT reclaimed at finalisation (foreman-gr27). `cleanup:
  always`/`on_success` asked for it to be removed and `git worktree remove` (never
  forced: it must not destroy uncommitted work) refused, typically because the
  worktree holds uncommitted or untracked files. The directory therefore stays on
  disk; this event is the run-level record of that fact.

  `path` is the retained worktree, `repo_id` the repository it belongs to, and
  `reason` the rendered cleanup failure. The run's status is unchanged: the work
  it produced was already proposed, so a cleanup refusal does not fail it.
  """
  @enforce_keys [:run_id, :repo_id, :path, :reason, :at]
  @type t :: %__MODULE__{
          run_id: String.t(),
          repo_id: String.t(),
          path: String.t(),
          reason: String.t(),
          at: non_neg_integer()
        }
  @derive Jason.Encoder
  defstruct [:run_id, :repo_id, :path, :reason, :at]
end
