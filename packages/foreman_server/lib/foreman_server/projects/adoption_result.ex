defmodule ForemanServer.Projects.AdoptionResult do
  @moduledoc """
  Typed outcome of `ForemanServer.Projects.AdoptionService`.

  `adopted?` is `false` when the subject already lived in the target project
  (an idempotent replay); the archive sync still ran. `archive_updates` has one
  entry per moved run/jobsite archive: `:updated`, `:missing` (older runs predate
  archiving; not an error) or `:failed` (logged, never fails the adoption).
  `mode` is `"move"` or `"mint"`; for a continuation it says how the new thread
  was started: `"forked"` (it forks the source's provider session, `adopt
  --continue --fork`) or `"context_seeded"` (its prompt is built from the session
  archive). `new_task_id` is set only for continuations, and so is `source_branch`: the
  branch their worktree was cut from when `from_source_branch` was asked for (`nil`
  when it was cut from the project's current branch); `minted_project_id` only
  for `"mint"`.
  """

  @enforce_keys [:mode, :subject_kind, :subject_id, :project_id, :from_project_id, :adopted?]
  defstruct [
    :mode,
    :subject_kind,
    :subject_id,
    :project_id,
    :from_project_id,
    :adopted?,
    :new_task_id,
    :source_branch,
    :minted_project_id,
    moved: %{task_ids: [], run_ids: [], jobsite_ids: []},
    archive_updates: []
  ]

  @type archive_status :: :updated | :missing | :failed

  @type t :: %__MODULE__{
          mode: String.t(),
          subject_kind: String.t(),
          subject_id: String.t(),
          project_id: String.t(),
          from_project_id: String.t(),
          adopted?: boolean(),
          new_task_id: String.t() | nil,
          source_branch: String.t() | nil,
          minted_project_id: String.t() | nil,
          moved: %{task_ids: [String.t()], run_ids: [String.t()], jobsite_ids: [String.t()]},
          archive_updates: [%{path: String.t(), status: archive_status()}]
        }
end
