defmodule ForemanServer.Events.InboxDeliveryUpdated do
  @moduledoc "Typed event emitted when a message delivery status is updated in a run's inbox thread."
  @enforce_keys [:run_id, :message_id, :delivery_status]
  @type t :: %__MODULE__{
          run_id: String.t(),
          message_id: String.t(),
          delivery_status: String.t(),
          metadata: map()
        }
  @derive Jason.Encoder
  defstruct [:run_id, :message_id, :delivery_status, metadata: %{}]
end
