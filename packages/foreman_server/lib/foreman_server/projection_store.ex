defmodule ForemanServer.ProjectionStore do
  @moduledoc "In-memory read model rebuilt from the durable event log at boot."

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec apply_event(map()) :: :ok
  def apply_event(event) when is_map(event) do
    GenServer.call(__MODULE__, {:apply_event, event})
  end

  @spec snapshot() :: map()
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @impl true
  def init(_opts) do
    {:ok, empty_projection()}
  end

  @impl true
  def handle_call({:apply_event, event}, _from, projection) do
    {:reply, :ok, reduce_event(projection, event)}
  end

  def handle_call(:snapshot, _from, projection) do
    {:reply, projection, projection}
  end

  defp empty_projection do
    %{commands: %{}, last_sequence: 0}
  end

  defp reduce_event(
         projection,
         %{event_type: "CommandAccepted", payload: %{command_id: command_id}} = event
       ) do
    projection
    |> put_in([:commands, command_id], event.payload)
    |> Map.put(:last_sequence, event.stream_version)
  end

  defp reduce_event(
         projection,
         %{type: "CommandAccepted", payload: %{command_id: command_id}} = event
       ) do
    projection
    |> put_in([:commands, command_id], event.payload)
    |> Map.put(:last_sequence, event.sequence)
  end

  defp reduce_event(projection, %{stream_version: stream_version}) do
    Map.put(projection, :last_sequence, stream_version)
  end

  defp reduce_event(projection, %{sequence: sequence}) do
    Map.put(projection, :last_sequence, sequence)
  end
end
