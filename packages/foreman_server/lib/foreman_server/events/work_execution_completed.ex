defmodule ForemanServer.Events.WorkExecutionCompleted do
  @moduledoc "Typed event emitted when a work request execution completes successfully."
  @enforce_keys [:work_id, :run_id]
  @type t :: %__MODULE__{
          work_id: String.t(),
          run_id: String.t()
        }
  @derive Jason.Encoder
  defstruct [:work_id, :run_id]
end
