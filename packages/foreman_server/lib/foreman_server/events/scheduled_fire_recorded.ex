defmodule ForemanServer.Events.ScheduledFireRecorded do
  @moduledoc "Emitted when the scheduler records intent to fire a scheduled task."
  @derive Jason.Encoder
  defstruct [:intent_id, :task_id, :run_id, :scheduled_for]
end
