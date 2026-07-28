defmodule ForemanServer.EventStore do
  use EventStore, otp_app: :foreman_server

  @doc """
  Read a single event by its globally unique event_id.

  Returns `{:ok, EventStore.RecordedEvent.t()}` if found,
  or `{:error, :event_not_found}`.
  """
  def read_event(event_id, _opts \\ []) do
    case Enum.find_value(stream_all_forward(0, []), fn
      %{event_id: ^event_id} = event -> {:ok, event}
      _ -> false
    end) do
      {:ok, event} -> {:ok, event}
      nil -> {:error, :event_not_found}
    end
  end
end
