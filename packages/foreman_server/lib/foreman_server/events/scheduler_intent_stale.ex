defmodule ForemanServer.Events.SchedulerIntentStale do
  @moduledoc "Emitted when Recovery marks a recorded fire intent as stale and re-dispatches."
  @derive Jason.Encoder
  defstruct [:intent_id, :task_id, :run_id, :marked_stale_at]
end
