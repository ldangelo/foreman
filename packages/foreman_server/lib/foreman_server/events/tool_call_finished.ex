defmodule ForemanServer.Events.ToolCallFinished do
  @moduledoc "Typed event emitted when a worker completes a tool call."
  @enforce_keys [:worker_id, :run_id]
  @type t :: %__MODULE__{
          worker_id: String.t(),
          run_id: String.t(),
          sequence: non_neg_integer() | nil,
          tool_name: String.t() | nil,
          result: term() | nil
        }
  @derive Jason.Encoder
  defstruct [:worker_id, :run_id, :sequence, :tool_name, :result]
end