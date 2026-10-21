defmodule ForemanServer.Events.ProjectAdmissionDeferred do
  @moduledoc """
  Typed event emitted when run admission refused a task for a genuine
  admission reason (`daily_thread_cap_exceeded`, `run_limit_exceeded`,
  `project_paused`). The refusal is retried later, so this is a durable
  counter fact, not a failure. `day` is the UTC date fixed at command time so
  replay never consults a clock.
  """
  @enforce_keys [:project_id, :reason, :day]
  @type t :: %__MODULE__{
          project_id: String.t(),
          reason: String.t(),
          day: String.t(),
          task_id: String.t() | nil
        }
  @derive Jason.Encoder
  defstruct [:project_id, :reason, :day, :task_id]
end
