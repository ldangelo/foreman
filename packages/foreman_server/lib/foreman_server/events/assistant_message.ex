defmodule ForemanServer.Events.AssistantMessage do
  @moduledoc "Typed event emitted when a worker produces an assistant message."
  @enforce_keys [:worker_id, :run_id]
  @type t :: %__MODULE__{
          worker_id: String.t(),
          run_id: String.t(),
          sequence: non_neg_integer() | nil,
          content: String.t() | nil
        }
  @derive Jason.Encoder
  defstruct [:worker_id, :run_id, :sequence, :content]
end