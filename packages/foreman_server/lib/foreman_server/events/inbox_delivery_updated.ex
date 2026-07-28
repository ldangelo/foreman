defmodule ForemanServer.Events.InboxDeliveryUpdated do
  @enforce_keys [:run_id, :message_id, :delivery_status]
  @type t :: %__MODULE__{
    run_id: String.t(),
    message_id: String.t(),
    delivery_status: String.t(),
    metadata: map() | nil
  }
  @derive Jason.Encoder
  defstruct [
    :run_id,
    :message_id,
    :delivery_status,
    :metadata
  ]
end
