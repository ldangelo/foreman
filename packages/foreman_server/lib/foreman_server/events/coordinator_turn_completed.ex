defmodule ForemanServer.Events.CoordinatorTurnCompleted do
  @moduledoc """
  Typed event: a coordinator turn finished. `cursor_message_id` is the last
  conversation message the turn consumed; everything after it is pending.
  """
  @enforce_keys [:project_id, :turn_id, :cursor_message_id, :at]
  @type t :: %__MODULE__{
          project_id: String.t(),
          turn_id: String.t(),
          cursor_message_id: String.t(),
          outcome: String.t() | nil,
          at: String.t()
        }
  @derive Jason.Encoder
  defstruct [:project_id, :turn_id, :cursor_message_id, :outcome, :at]
end
