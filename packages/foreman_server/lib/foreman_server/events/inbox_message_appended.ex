defmodule ForemanServer.Events.InboxMessageAppended do
  @enforce_keys [:run_id, :message_id, :body]
  @type t :: %__MODULE__{
    run_id: String.t(),
    message_id: String.t(),
    body: String.t(),
    metadata: map() | nil
  }
  @derive Jason.Encoder
  defstruct [
    :run_id,
    :message_id,
    :body,
    :metadata
  ]
end
