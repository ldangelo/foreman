defmodule ForemanServer.Events.ScheduleUpdated do
  @moduledoc """
  A schedule's definition changed. `changes` holds only the whitelisted fields
  that changed (`name`, `spec`, `prompt`, `workflow`, `auto_approve`, `overlap`,
  `misfire_grace_seconds`), string-keyed; `spec`, when present, is the normalised
  spec map.
  """
  @enforce_keys [:schedule_id, :project_id, :changes, :updated_at]
  @type t :: %__MODULE__{
          schedule_id: String.t(),
          project_id: String.t(),
          changes: %{String.t() => term()},
          updated_at: String.t()
        }
  @derive Jason.Encoder
  defstruct [:schedule_id, :project_id, :changes, :updated_at]
end
