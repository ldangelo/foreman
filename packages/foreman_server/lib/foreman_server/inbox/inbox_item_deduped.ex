defmodule ForemanServer.Inbox.InboxItemDeduped do
  @moduledoc """
  TRD-001: Domain event emitted when an inbox item is a duplicate within
  the configured dedupe window. The `:existing` field carries the prior
  `InboxItemStarted` so the caller can return the existing delivery
  status without re-processing the payload.
  """
  @derive Jason.Encoder
  defstruct [:correlation_id, :source, :existing]

  @type t :: %__MODULE__{
          correlation_id: String.t(),
          source: module(),
          existing: map() | nil
        }
end
