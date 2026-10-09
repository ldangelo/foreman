defmodule ForemanServer.Events.JobsitePaused do
  @moduledoc """
  Typed event emitted when a jobsite run is paused.

  Pausing is NOT terminal: `Aggregates.Jobsite.apply_event/2` must leave
  `terminal?: false` for this event, because a paused jobsite still accepts
  the commands `resume` dispatches.
  """
  @enforce_keys [:jobsite_id, :reason]
  @type t :: %__MODULE__{
          jobsite_id: String.t(),
          reason: String.t(),
          iteration_index: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [:jobsite_id, :reason, :iteration_index]
end
