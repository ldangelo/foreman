defmodule ForemanServer.EventStore do
  use EventStore, otp_app: :foreman_server

  @page_size 1_000

  @doc """
  Read a single event by its globally unique event_id.

  Returns `{:ok, EventStore.RecordedEvent.t()}` if found,
  or `{:error, :event_not_found}`.

  Pages through `read_all_streams_forward/3` to look up the event by
  `event_id` (UUID), advancing by the last seen `event_number` so events
  beyond any single page are still reachable.
  """
  def read_event(event_id, opts \\ [])

  def read_event(event_id, opts) when is_binary(event_id) do
    scan_forward(event_id, 0, opts, &read_all_streams_forward/3)
  end

  def read_event(_event_id, _opts), do: {:error, :event_not_found}

  @doc false
  def scan_forward(event_id, start_version, opts, page_reader)
      when is_function(page_reader, 3) do
    case page_reader.(start_version, @page_size, opts) do
      {:ok, []} ->
        {:error, :event_not_found}

      {:ok, events} ->
        case Enum.find(events, fn event -> event.event_id == event_id end) do
          nil ->
            last_number = events |> List.last() |> Map.get(:event_number)
            scan_forward(event_id, last_number + 1, opts, page_reader)

          event ->
            {:ok, event}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
