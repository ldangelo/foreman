defmodule ForemanServer.Events.ScheduleFired do
  @moduledoc """
  A due slot produced a task. `slot` is unix seconds; `collapsed_count` is how
  many earlier due slots were collapsed into this one after downtime (they never
  fire).
  """
  @enforce_keys [:schedule_id, :project_id, :slot, :task_id, :intent_id, :fired_at]
  @type t :: %__MODULE__{
          schedule_id: String.t(),
          project_id: String.t(),
          slot: integer(),
          task_id: String.t(),
          intent_id: String.t(),
          collapsed_count: non_neg_integer() | nil,
          fired_at: String.t()
        }
  @derive Jason.Encoder
  defstruct [:schedule_id, :project_id, :slot, :task_id, :intent_id, :collapsed_count, :fired_at]
end
