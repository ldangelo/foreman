defmodule ForemanServer.CommandedApplication do
  @moduledoc """
  Minimal Commanded application that wires the EventStore adapter.

  The adapter owns and starts ForemanServer.EventStore, so it must appear
  before ForemanServer.EventStore in the OTP supervision tree. We do NOT
  list ForemanServer.EventStore separately — the adapter's child_spec starts it.

  Used by Actor and CommandRouter for all persistence via
  Commanded.EventStore.append_to_stream and stream_forward.
  """

  use Commanded.Application,
    otp_app: :foreman_server,
    event_store: [
      adapter: ForemanServer.EventStoreAdapter,
      event_store: ForemanServer.EventStore
    ]
end
