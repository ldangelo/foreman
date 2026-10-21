defmodule ForemanServer.Events.CoordinatorTurnStarted do
  @moduledoc """
  Typed event: a coordinator turn began. `trigger_message_ids` are the
  conversation messages the turn consumes; `attempt` counts re-runs of the same
  trigger after an interruption or failure.
  """
  @enforce_keys [:project_id, :turn_id, :attempt, :at]
  @type t :: %__MODULE__{
          project_id: String.t(),
          turn_id: String.t(),
          attempt: pos_integer(),
          trigger_message_ids: [String.t()],
          at: String.t()
        }
  @derive Jason.Encoder
  defstruct [:project_id, :turn_id, :attempt, :at, trigger_message_ids: []]
end
