defmodule ForemanServer.Events.SchedulerIntentStale do
  @moduledoc """
  Emitted by recovery, once per interrupted intent, when a recorded fire intent
  was neither confirmed nor skipped within the grace period.
  """
  @enforce_keys [:intent_id]
  @type t :: %__MODULE__{
          intent_id: String.t(),
          task_id: String.t() | nil,
          run_id: String.t() | nil,
          marked_stale_at: String.t() | nil
        }
  @derive Jason.Encoder
  defstruct [:intent_id, :task_id, :run_id, :marked_stale_at]
end
