defmodule ForemanServer.Overwatch.Adapters.HeartbeatWorker do
  @moduledoc """
  Default adapter that emits periodic `WorkerHeartbeat` events and stays
  alive. It is the production fallback used by `ForemanServer.Overwatch`
  when no specialized runtime is configured.

  ## Behavior

    * On `start_link/1`: emits one immediate `WorkerHeartbeat`, then
      schedules a heartbeat every `heartbeat_interval_ms` (default
      5_000ms). Stays alive until killed.
    * Emits via `WorkerProtocol.emit/2` (which routes through
      `Tracker.heartbeat/3`).
    * Listens for `{:overwatch_activate, worker_id, run_id, parent}`
      and acknowledges with `{:overwatch_activated, self()}`.

  ## Configuration

    * `:heartbeat_interval_ms` — cadence of heartbeats. Default 5_000.
  """

  use GenServer
  alias ForemanServer.Overwatch.WorkerProtocol

  @default_heartbeat_interval_ms 5_000

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  # ------------------------------------------------------------------
  # GenServer
  # ------------------------------------------------------------------

  @impl true
  def init(opts) do
    worker_id = Keyword.fetch!(opts, :worker_id)
    run_id = Keyword.fetch!(opts, :run_id)
    interval = Keyword.get(opts, :heartbeat_interval_ms, @default_heartbeat_interval_ms)

    Process.send_after(self(), :heartbeat, interval)

    state = %{
      worker_id: worker_id,
      run_id: run_id,
      interval: interval
    }

    {:ok, state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    _ = WorkerProtocol.emit(:heartbeat, %{worker_id: state.worker_id, run_id: state.run_id})

    Process.send_after(self(), :heartbeat, state.interval)
    {:noreply, state}
  end

  def handle_info({:overwatch_activate, _worker_id, _run_id, parent}, state) do
    send(parent, {:overwatch_activated, self()})
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
