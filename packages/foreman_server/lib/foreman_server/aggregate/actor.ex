defmodule ForemanServer.Aggregate.Actor do
  @moduledoc """
  OTP actor that owns one aggregate stream.

  Rehydrates state via `Aggregate.load/2` on startup, validates commands against the
  actor's cached aggregate state, and appends with the cached stream version. When a
  concurrent writer wins the race, the actor reloads once and re-runs the command
  against the authoritative event-store state before replying.

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

  alias ForemanServer.{Aggregate, EventStore, ProjectionStore}

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
    case execute_command(s, command_type, payload, command_id) do
      {:ok, result, next_state} ->
        {:reply, {:ok, result}, next_state}

      {:error, reason, next_state} ->
        Logger.warning("[Aggregate.Actor] command failed",
          command_type: command_type, reason: reason)

        {:reply, {:error, reason}, next_state}
    end
  end

  defp execute_command(s, command_type, payload, command_id) do
    payload = Map.put_new(payload, :command_id, command_id)

    with {:ok, event_spec} <- s.module.handle_command(s.state, %{type: command_type, payload: payload}),
         {:ok, result, next_state} <- append_event(s, event_spec, command_id) do
      {:ok, result, next_state}
    else
      {:error, {:conflict, _details}} ->
        retry_after_conflict(s, command_type, payload, command_id)

      {:error, reason} ->
        {:error, reason, s}

      :unhandled ->
        {:error, :unhandled, s}
    end
  end

  defp retry_after_conflict(s, command_type, payload, command_id) do
    {fresh_state, fresh_version} = Aggregate.load(s.module, s.stream_id)
    refreshed = %{s | state: fresh_state, version: fresh_version}

    Logger.debug("[Aggregate.Actor] retrying after conflict",
      stream_id: s.stream_id,
      command_type: command_type,
      version: fresh_version
    )

    case refreshed.module.handle_command(fresh_state, %{type: command_type, payload: payload}) do
      {:ok, event_spec} ->
        case append_event(refreshed, event_spec, command_id) do
          {:ok, result, next_state} -> {:ok, result, next_state}
          {:error, reason} -> {:error, reason, refreshed}
        end

      {:error, reason} ->
        {:error, reason, refreshed}

      :unhandled ->
        {:error, :unhandled, refreshed}
    end
  end

  defp append_event(s, event_spec, command_id) do
    stream_id = Map.fetch!(event_spec, :stream_id)

    append_input =
      %{
        stream_id: stream_id,
        event_type: Map.fetch!(event_spec, :event_type),
        payload:
          event_spec
          |> Map.fetch!(:payload)
          |> Map.put_new(:command_id, command_id)
          |> Map.put_new(:updated_at, DateTime.utc_now()),
        metadata: %{
          correlation_id: command_id,
          source: "aggregate_actor",
          idempotency_key: command_id
        },
        correlation_id: command_id,
        expected_stream_version: Map.get(event_spec, :expected_stream_version, s.version)
      }

    case EventStore.append(append_input) do
      {:ok, event} ->
        {new_state, new_version} = Aggregate.load(s.module, s.stream_id)
        Logger.debug("[Aggregate.Actor] stream=#{s.stream_id} version=#{new_version}")

        {:ok,
         %{event: event, audit_events: [], projection: ProjectionStore.snapshot()},
         %{s | state: new_state, version: new_version}}

      {:error, reason} ->
        {:error, reason}
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
