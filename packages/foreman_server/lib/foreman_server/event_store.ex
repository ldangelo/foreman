defmodule ForemanServer.EventStore do
  use EventStore, otp_app: :foreman_server

  @doc """
  Read a single event by its globally unique event_id.

  Returns `{:ok, EventStore.RecordedEvent.t()}` if found,
  or `{:error, :event_not_found}`.
  """
  def read_event(event_id, opts \\ []) do
    read_event_by_id(event_id, opts)
  end
end
