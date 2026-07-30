defmodule ForemanServer.Commands.StartInboxItem do
  @moduledoc "Command to submit an inbox item through the SharedInbox ingestion gate."

  @enforce_keys [:correlation_id, :source, :payload]
  @type t :: %__MODULE__{
          correlation_id: String.t(),
          source: String.t(),
          payload: map(),
          idempotency_key: String.t() | nil
        }
  @derive Jason.Encoder
  defstruct [:correlation_id, :source, :payload, idempotency_key: nil]
end
