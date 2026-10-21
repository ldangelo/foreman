defmodule ForemanServer.Events.ScheduleFireSkipped do
  @moduledoc """
  A due slot was deliberately not fired. `reason` is one of `missed`, `overlap`,
  `project_paused`, `daily_cap`, `error`. The slot is consumed: it is never
  retried. `missed_count` is set for `missed`; `detail` carries the error text
  for `error`.
  """
  @enforce_keys [:schedule_id, :project_id, :slot, :reason, :skipped_at]
  @type t :: %__MODULE__{
          schedule_id: String.t(),
          project_id: String.t(),
          slot: integer(),
          reason: String.t(),
          missed_count: non_neg_integer() | nil,
          detail: String.t() | nil,
          skipped_at: String.t()
        }
  @derive Jason.Encoder
  defstruct [:schedule_id, :project_id, :slot, :reason, :missed_count, :detail, :skipped_at]
end
