defmodule ForemanServer.Inbox.InboxItemStarted do
  @moduledoc """
  TRD-001: Domain event emitted the first time an inbox item is seen
  within the configured dedupe window.

  Persisted by the inbox ingestion path through the event store; the
  `Inbox.DedupeTable` ETS mirror is the runtime cache for the dedupe
  decision. This is the in-memory struct used by `SharedInbox.ingest/2`.
  """
  @derive Jason.Encoder
  defstruct [:correlation_id, :source, :payload, :timestamp]

  @type t :: %__MODULE__{
          correlation_id: String.t(),
          source: module(),
          payload: map(),
          timestamp: non_neg_integer() | nil
        }
end
