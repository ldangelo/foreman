defmodule ForemanServer.Events.WorkCancelled do
  @moduledoc "Typed event emitted when a work request is cancelled."
  @enforce_keys [:work_id]
  @type t :: %__MODULE__{
          work_id: String.t()
        }
  @derive Jason.Encoder
  defstruct [:work_id]
end
