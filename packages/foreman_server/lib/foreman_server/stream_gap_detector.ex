defmodule ForemanServer.StreamGapDetector do
  @moduledoc """
  Supervised monitor that compares the projection-store's per-stream versions
  against `EventStore.stream_version/1` and blocks command appends to any
  stream whose actual version has drifted from its projected version.

  The alert itself is appended to a dedicated `stream_gap_alerts` stream
  via `ForemanServer.CommandRouter.handle/1` so the gap-guard path matches
  every other domain path. `EventStore.append/1` keeps a narrow bypass for
  that alerts stream only.
  """

  use GenServer

  alias ForemanServer.{CommandRouter, EventStore, ProjectionStore}

  @scan_interval_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def check(stream_id) when is_binary(stream_id),
    do: GenServer.call(__MODULE__, {:check, stream_id})

  def resolve(stream_id) when is_binary(stream_id),
    do: GenServer.call(__MODULE__, {:resolve, stream_id})

  @impl true
  def init(_opts) do
    schedule_scan()
    {:ok, %{blocked_streams: MapSet.new()}}
  end

  @impl true
  def handle_call({:check, stream_id}, _from, state) do
    reply = if MapSet.member?(state.blocked_streams, stream_id), do: :blocked, else: :ok
    {:reply, reply, state}
  end

  def handle_call({:resolve, stream_id}, _from, state) do
    {:reply, :ok, %{state | blocked_streams: MapSet.delete(state.blocked_streams, stream_id)}}
  end

  @impl true
  def handle_info(:scan, state) do
    projected_versions = safe_projected_versions()

    state =
      Enum.reduce(projected_versions, state, fn {stream_id, projected_version}, acc ->
        detect_gap(acc, stream_id, projected_version)
      end)

    schedule_scan()
    {:noreply, state}
  end

  defp safe_projected_versions do
    if Process.whereis(ProjectionStore) do
      ProjectionStore.projected_stream_versions()
    else
      %{}
    end
  end

  defp detect_gap(state, stream_id, projected_version) do
    actual_version = EventStore.stream_version(stream_id)

    if actual_version == projected_version do
      state
    else
      unless MapSet.member?(state.blocked_streams, stream_id) do
        _ =
          CommandRouter.handle(%{
            command_id: "stream-gap-alert:#{stream_id}:#{actual_version}",
            command_type: "stream_gap.detect",
            payload: %{
              affected_stream_id: stream_id,
              projected_version: projected_version,
              actual_version: actual_version
            }
          })
      end

      %{state | blocked_streams: MapSet.put(state.blocked_streams, stream_id)}
    end
  end

  defp schedule_scan do
    interval =
      Application.get_env(:foreman_server, :stream_gap_scan_interval_ms, @scan_interval_ms)

    Process.send_after(self(), :scan, interval)
  end
end
