defmodule ForemanServer.Events.SchedulePaused do
  @moduledoc "A schedule was paused. `at` is the ISO-8601 UTC instant."
  @enforce_keys [:schedule_id, :project_id, :at]
  @type t :: %__MODULE__{schedule_id: String.t(), project_id: String.t(), at: String.t()}
  @derive Jason.Encoder
  defstruct [:schedule_id, :project_id, :at]
end
