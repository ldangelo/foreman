defmodule ForemanServer.Inbox.StartInboxItem do
  @moduledoc """
  TRD-001: Canonical ingestion command. Every ingestion source (attach
  bridge, external trigger poller) emits this command after deriving a
  correlation id via `InboxItemCorrelationId.correlation_id/1`.

  The command is dispatched through `CommandRouter` and becomes the
  `InboxItemStarted` event in the event log. The runtime dedupe decision
  lives in `SharedInbox.ingest/2` (in-process), not in the command
  handler.
  """
  @derive Jason.Encoder
  defstruct [:correlation_id, :source, :payload, :timestamp]

  @type t :: %__MODULE__{
          correlation_id: String.t(),
          source: module(),
          payload: map(),
          timestamp: non_neg_integer() | nil
        }

  def new(source_module, payload) do
    %__MODULE__{
      correlation_id: nil,
      source: source_module,
      payload: payload,
      timestamp: System.system_time(:millisecond)
    }
  end

  def with_correlation_id(%__MODULE__{} = cmd, correlation_id) do
    %__MODULE__{cmd | correlation_id: correlation_id}
  end
end
