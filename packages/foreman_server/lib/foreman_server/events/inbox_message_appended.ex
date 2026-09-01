defmodule ForemanServer.Events.InboxMessageAppended do
  @moduledoc "Typed event emitted when a message is appended to a run's operator inbox thread."
  @enforce_keys [:run_id, :message_id, :body]
  @type t :: %__MODULE__{
          run_id: String.t(),
          message_id: String.t(),
          body: String.t(),
          metadata: map()
        }
  @derive Jason.Encoder
  defstruct [:run_id, :message_id, :body, metadata: %{}]
end
