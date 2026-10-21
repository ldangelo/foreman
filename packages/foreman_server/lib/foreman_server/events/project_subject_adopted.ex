defmodule ForemanServer.Events.ProjectSubjectAdopted do
  @moduledoc """
  Typed event emitted on the TARGET `project:<id>` stream when a session is
  adopted into a project (`project.adopt`).

  `mode` is `"move"` or `"continue"`:

    * `"move"` re-homes the subject: the `ProjectionStore` fold rewrites
      `project_id` on the projected task, its runs and/or the jobsite from
      `from_project_id` to `project_id`. Event history is immutable, so the
      original events keep their original `project_id`; only the projection
      (and the on-disk archive manifest) change.
    * `"continue"` re-homes nothing. It records that `new_task_id` (a NEW thread
      in `project_id`) continues the source subject.

  `moved` is `%{task_ids, run_ids, jobsite_ids}` (string keys when decoded from
  the event store). `archive_paths` are the archive directories whose manifest
  the adoption facade updates after dispatch.
  """
  @enforce_keys [:project_id, :subject_kind, :subject_id, :mode, :from_project_id, :adopted_at]
  @type t :: %__MODULE__{
          project_id: String.t(),
          subject_kind: String.t(),
          subject_id: String.t(),
          mode: String.t(),
          from_project_id: String.t(),
          moved: map(),
          repo_path: String.t() | nil,
          archive_paths: [String.t()],
          new_task_id: String.t() | nil,
          adopted_at: String.t()
        }
  @derive Jason.Encoder
  defstruct [
    :project_id,
    :subject_kind,
    :subject_id,
    :mode,
    :from_project_id,
    :repo_path,
    :new_task_id,
    :adopted_at,
    moved: %{task_ids: [], run_ids: [], jobsite_ids: []},
    archive_paths: []
  ]
end
