defmodule ForemanServer.Overwatch do
  @moduledoc """
  Worker lifecycle supervisor: receives heartbeats from running workers and
  monitors their processes. Emits `:telemetry` events for heartbeat/exit so
  downstream observers can react.

  The stuck-run detection sub-item of TRD-040 is intentionally NOT
  implemented here. TRD-020 specifies a configurable `StuckDetector` with
  a 15-minute threshold, ProjectionStore scan, and `RunFlaggedStuck`
  command/event. Until TRD-020 supplies the real call site, the
  `[:foreman, :run, :stuck]` event is not emitted.
  """

  use GenServer

  alias ForemanServer.Telemetry

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def heartbeat(metadata), do: heartbeat(__MODULE__, metadata)

  def heartbeat(server, metadata) when is_map(metadata) do
    GenServer.call(server, {:heartbeat, metadata})
  end

  def monitor_worker(pid, metadata \\ %{}), do: monitor_worker(__MODULE__, pid, metadata)

  def monitor_worker(server, pid, metadata) when is_pid(pid) and is_map(metadata) do
    GenServer.call(server, {:monitor_worker, pid, metadata})
  end

  @impl true
  def init(_opts) do
    {:ok, %{monitors: %{}}}
  end

  @impl true
  def handle_call({:heartbeat, metadata}, _from, state) do
    Telemetry.worker_heartbeat(%{count: 1}, metadata)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:monitor_worker, pid, metadata}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, ref, %{state | monitors: Map.put(state.monitors, ref, metadata)}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {metadata, monitors} = Map.pop(state.monitors, ref, %{})

    Telemetry.worker_exit(%{count: 1}, Map.put(metadata, :reason, inspect(reason)))

    {:noreply, %{state | monitors: monitors}}
  end
end
