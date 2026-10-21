defmodule ForemanServer.Events.RunStarted do
  @moduledoc "Typed event emitted when a run has started."
  # workflow_snapshot was added later — older events predate it, so it is NOT enforced.
  # task_id and source were relaxed for work-flow runs which have no task_id.
  # `repo_id` / `repo_ids` (E12): primary repo (when not the project primary) and
  # initial extra repos for work runs. Optional, NOT enforced; absent for
  # single-repo runs.
  @enforce_keys [:run_id, :project_id]
  @type t :: %__MODULE__{
          run_id: String.t(),
          sequence: non_neg_integer() | nil,
          task_id: String.t() | nil,
          project_id: String.t(),
          source: :task | :work | nil,
          workflow_name: String.t() | nil,
          workflow_digest: String.t() | nil,
          workflow_snapshot: map() | nil,
          started_at_ms: non_neg_integer() | nil,
          repo_id: String.t() | nil,
          repo_ids: [String.t()] | nil
        }
  @derive Jason.Encoder
  defstruct [
    :run_id,
    :sequence,
    :task_id,
    :project_id,
    :source,
    :workflow_name,
    :workflow_digest,
    :workflow_snapshot,
    :started_at_ms,
    :repo_id,
    :repo_ids
  ]
end
