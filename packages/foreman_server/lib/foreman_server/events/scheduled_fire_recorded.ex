defmodule ForemanServer.Events.ScheduledFireRecorded do
  @moduledoc """
  Emitted when the scheduler records intent to fire a scheduled task: the first
  half of the crash-safe two-phase fire marker (`ScheduledFireConfirmed` is the
  second). `schedule_id`, `project_id` and `slot` (unix seconds) identify which
  fire the intent belongs to so recovery can redo it.
  """
  @enforce_keys [:intent_id]
  @type t :: %__MODULE__{
          intent_id: String.t(),
          schedule_id: String.t() | nil,
          project_id: String.t() | nil,
          slot: integer() | nil,
          task_id: String.t() | nil,
          run_id: String.t() | nil,
          scheduled_for: String.t() | nil,
          scheduled_at: String.t() | nil,
          payload: map() | nil
        }
  @derive Jason.Encoder
  defstruct [
    :intent_id,
    :schedule_id,
    :project_id,
    :slot,
    :task_id,
    :run_id,
    :scheduled_for,
    :scheduled_at,
    :payload
  ]
end
