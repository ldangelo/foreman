defmodule ForemanServer.Aggregate.Actor do
  @moduledoc """
  OTP actor that owns one aggregate stream.

  Rehydrates state via `Aggregate.load/2` on startup, dispatches commands through
  `CommandRouter.handle/1`, and reloads from the event store after each confirmed
  append.  The router derives the stream from the payload; if it differs from the
  actor's cached stream the reload will reveal the mismatch rather than silently
  corrupting local state.

  Supervision: `restart: :permanent` via the owning supervisor — a crashed actor is
  always restarted and rehydrates before processing the next command.

  ## `command_id` requirement

  Every call to `command/4` MUST supply a stable, operation-specific `command_id`.
  This is critical for:
  - **Restart idempotency** — a restarted actor re-sending the same command must
    hit the EventStore dedup window, not append a duplicate event.
  - **Operation isolation** — two different operations on the same stream
    (e.g. `tool.request` vs `tool.approve` for the same `tool_call_id`) must have
    distinct `command_id` values, otherwise one appends as a duplicate of the other.

  Suggested command_id patterns:
  - worker.record: \`"worker:\#{run_id}:\#{worker_id}:\#{event_type}:\#{sequence}"\`
  - tool.request: \`"tool:\#{run_id}:\#{tool_call_id}:request"\`
  - run.phase.nudge (overwatch): \`"nudge:\#{run_id}:\#{phase_id}:\#{nudge_count}"\`
  """

  use GenServer
  require Logger

  alias ForemanServer.Aggregate
  alias ForemanServer.CommandRouter

  # ------------------------------------------------------------------
  # Client
  # ------------------------------------------------------------------

  @spec start_link(module(), String.t()) :: GenServer.on_start()
  def start_link(module, stream_id) do
    GenServer.start_link(__MODULE__, {module, stream_id})
  end

  @spec command(pid(), String.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def command(pid, command_type, payload, command_id) do
    GenServer.call(pid, {:command, command_type, payload, command_id})
  end

  @spec current_state(pid()) :: Aggregate.state()
  def current_state(pid), do: GenServer.call(pid, :state)

  # ------------------------------------------------------------------
  # Server
  # ------------------------------------------------------------------

  @impl true
  def init({module, stream_id}) do
    Process.flag(:trap_exit, true)
    {agg_state, version} = Aggregate.load(module, stream_id)
    Logger.debug("[Aggregate.Actor] stream=#{stream_id} version=#{version}")
    {:ok, %{module: module, stream_id: stream_id, state: agg_state, version: version}}
  end

  @impl true
  def handle_call(:state, _from, %{state: state} = s) do
    {:reply, state, s}
  end

  def handle_call({:command, command_type, payload, command_id}, _from, s) do
    cmd = %{
      command_id: command_id,
      command_type: command_type,
      payload: payload
    }

    case CommandRouter.handle(cmd) do
      {:ok, result} ->
        # Router confirmed the append.  Reload so the actor's cached state matches
        # the authoritative event-store stream.  If the router resolved a different
        # stream than s.stream_id the reload will pull the correct events.
        {new_state, new_version} = Aggregate.load(s.module, s.stream_id)
        Logger.debug("[Aggregate.Actor] stream=#{s.stream_id} version=#{new_version}")
        {:reply, {:ok, result}, %{s | state: new_state, version: new_version}}

      {:error, reason} ->
        Logger.warning("[Aggregate.Actor] command failed",
          command_type: command_type, reason: reason)
        {:reply, {:error, reason}, s}
    end
  end

  # ------------------------------------------------------------------
  # Termination
  # ------------------------------------------------------------------

  @impl true
  def handle_info({:EXIT, _pid, :normal}, s), do: {:stop, :normal, s}
  def handle_info({:EXIT, pid, reason}, s) do
    Logger.info("[Aggregate.Actor] linked process exit pid=#{inspect(pid)} reason=#{reason}")
    {:noreply, s}
  end
end
