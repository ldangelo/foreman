defmodule ForemanServer.Events.RunResumed do
  @moduledoc """
  Typed event emitted when a paused run is resumed via `run.resume`.

  Re-admits the run to `status: "awaiting_worker", terminal?: false` on
  the Run aggregate. `ForemanServer.Workflow.Dispatcher` reacts to this
  event by re-acquiring the run's admission gates (global slot, and the
  per-DB Beads lease when applicable — both released when the run was
  paused) and restarting `RunExecutor` at the first non-completed phase.
  """
  @enforce_keys [:run_id]
  @type t :: %__MODULE__{
          run_id: String.t(),
          project_id: String.t() | nil,
          reason: String.t() | nil,
          actor: String.t() | nil,
          sequence: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [:run_id, :project_id, :reason, :actor, :sequence]
end
