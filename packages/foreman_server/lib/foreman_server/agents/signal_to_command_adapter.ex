defmodule ForemanServer.Agents.SignalToCommandAdapter do
  @moduledoc """
  Jido.Signal subscriber that normalizes CloudEvents on the
  `foreman/commands` topic into Foreman `ExternalTriggerCommand`
  envelopes and routes them through `ForemanServer.CommandGateway`
  (TRD-2026-4212be7e, JCR-T005).

  ## Why this module exists

  Jido agents publish CloudEvents to a `Jido.Signal.Bus` topic named
  `foreman/commands`. The Foreman CQRS spine expects aggregates (in
  this case the `ExternalTrigger` aggregate) to receive events via
  `CommandGateway.dispatch_system/2` — the trusted-OTP entry point that
  the `EventStore.Enforcement` architecture test requires for all
  event-store writes.

  The adapter bridges the two:

  ```
   Jido.Signal.Bus topic "foreman/commands"
     │
     │  Jido.Signal struct (CloudEvent v1.0.2)
     ▼
   SignalToCommandAdapter.handle_info({:signal, signal}, state)
     │
     │  normalize → ExternalTriggerCommand envelope
     ▼
   dispatcher.(envelope)             (default: CommandGateway.dispatch_system/1)
     │
     ▼
   CommandRouter → EventStore (append)
  ```

  ## Injectable dispatcher

  Tests can pass a `:dispatcher` option (an MFA `{module, fun, args}` or
  anonymous function) to replace the real `CommandGateway.dispatch_system/1`
  call. The injected dispatcher is stored in state and called as
  `dispatcher.(envelope)` (for fns) or `apply(module, fun, [envelope | args])`
  (for MFAs). This lets the integration test assert exactly what envelope
  was delivered, without touching the real gateway.

  ## Topic

  Default topic is `foreman/commands`. Per JSI-T001 this is one of the
  four Jido signal topics Foreman configures; the others are
  `foreman/operator`, `foreman/inbox`, and `agents/<agent-id>/directive`
  (those have separate adapters and are out of scope for JCR-T005).

  ## Idempotency

  CloudEvents carry a unique `id`. The adapter passes it through to the
  envelope as `cloud_event_id` so the `ExternalTrigger` aggregate's
  dedupe machinery (which already keys on `trigger_id` / `dedupe_key` /
  `command_id` / `event_id`) can reject duplicates idempotently.
  """

  use GenServer

  require Logger

  alias ForemanServer.CommandGateway

  @default_topic "com.foreman.command.*"

  @default_dispatcher {CommandGateway, :dispatch_system, []}

  # --- public API --------------------------------------------------------

  @doc """
  Start the adapter as a GenServer.


    - `:name` — process name (default: `ForemanServer.Agents.SignalToCommandAdapter`).
    - `:dispatcher` — `{module, fun, args}` MFA or anonymous fn to call
      with the normalized envelope. Defaults to
      `{CommandGateway, :dispatch_system, []}`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Normalize a CloudEvent map (or `Jido.Signal` struct) to an
  `ExternalTriggerCommand` envelope.
  """
  @spec normalize(map() | struct()) ::
          {:ok, map()} | {:error, {:invalid_cloud_event, atom()}}
  def normalize(event) when is_map(event) do
    ce = to_map(event)

    with :ok <- require_specversion(ce),
         :ok <- require_trigger_id(ce) do
      cloud_event_id = ce["id"] || ce[:id]
      source = ce["source"] || ce[:source]
      trigger_id = trigger_id_of(ce)
      data = ce["data"] || ce[:data] || %{}

      {:ok,
       %{
         command_id: cloud_event_id,
         type: "external.trigger",
         aggregate_id: "external:#{trigger_id}",
         payload: %{
           trigger_id: trigger_id,
           cloud_event_id: cloud_event_id,
           source: source,
           command: data["command"] || data[:command],
           args: data["args"] || data[:args] || %{}
         }
       }}
    end
  end

  def normalize(_), do: {:error, {:invalid_cloud_event, :not_a_map}}

  @doc """
  Subscribe the adapter's GenServer pid to the `foreman/commands`
  topic on the given bus. Returns `:ok` on success.
  """
  @spec subscribe(GenServer.server(), keyword()) :: :ok | {:error, term()}
  def subscribe(bus, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.call(name, {:subscribe, bus})
  end

  @doc """
  Public pure entry: given a dispatcher (default
  `{CommandGateway, :dispatch_system, []}`) and a signal, normalize and
  dispatch. Returns `:ok` always; failures are logged, never raised
  (the bus is not allowed to crash on a malformed CloudEvent).
  """
  @spec handle_signal(map() | struct(), term(), keyword()) :: :ok
  def handle_signal(signal, dispatcher \\ @default_dispatcher, _opts \\ []) do
    case normalize(signal) do
      {:ok, envelope} ->
        case invoke_dispatcher(dispatcher, envelope) do
          {:ok, _event} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "SignalToCommandAdapter: dispatcher returned #{inspect(reason)} for cloud_event_id=#{envelope.payload.cloud_event_id}"
            )

            :ok

          other ->
            Logger.warning(
              "SignalToCommandAdapter: dispatcher returned unexpected #{inspect(other)} for cloud_event_id=#{envelope.payload.cloud_event_id}"
            )

            :ok
        end

      {:error, reason} ->
        Logger.warning("SignalToCommandAdapter: dropping malformed CloudEvent: #{inspect(reason)}")
        :ok
    end
  end

  # --- GenServer --------------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      bus: Keyword.get(opts, :bus),
      subscription_ref: nil,
      dispatcher: Keyword.get(opts, :dispatcher, @default_dispatcher)
    }

    # If a bus was provided at start, auto-subscribe so the adapter is
    # usable immediately when wired under supervision. The subscribe
    # call is deferred via `send/2` so the GenServer is fully
    # initialized before `handle_call/3` runs.
    if state.bus, do: send(self(), {:auto_subscribe, state.bus})

    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, bus}, _from, state) do
    case Jido.Signal.Bus.subscribe(bus, @default_topic,
           dispatch: {:pid, target: self()}
         ) do
      {:ok, ref} ->
        {:reply, :ok, %{state | bus: bus, subscription_ref: ref}}

      other ->
        {:reply, other, state}
    end
  end

  @impl true
  def handle_info({:auto_subscribe, bus}, state) do
    case Jido.Signal.Bus.subscribe(bus, @default_topic,
           dispatch: {:pid, target: self()}
         ) do
      {:ok, ref} ->
        {:noreply, %{state | bus: bus, subscription_ref: ref}}

      _other ->
        # Retry once after a short delay so a not-yet-ready bus can come
        # online. Tests start the bus before the adapter so this is
        # rarely needed; production wires the bus under supervision.
        Process.send_after(self(), {:auto_subscribe, bus}, 100)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:signal, signal}, state) do
    handle_signal(signal, state.dispatcher)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
  # --- internal helpers --------------------------------------------------

  defp invoke_dispatcher(fun, envelope) when is_function(fun, 1), do: fun.(envelope)

  defp invoke_dispatcher({module, fun, args}, envelope) when is_atom(module) and is_atom(fun) do
    apply(module, fun, [envelope | args])
  end

  defp to_map(%Jido.Signal{} = signal) do
    signal
    |> Map.from_struct()
    |> stringify_keys()
  end

  defp to_map(map) when is_map(map), do: stringify_keys(map)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp require_specversion(ce) do
    case ce["specversion"] || ce[:specversion] do
      "1.0" <> _ -> :ok
      _ -> {:error, {:invalid_cloud_event, :missing_specversion}}
    end
  end

  defp require_trigger_id(ce) do
    case trigger_id_of(ce) do
      nil -> {:error, {:invalid_cloud_event, :missing_trigger_id}}
      _ -> :ok
    end
  end

  defp trigger_id_of(ce) do
    # Check top-level first (CloudEvents extension), then data.
    top =
      ce["trigger_id"] ||
        ce[:trigger_id] ||
        ce["dedupe_key"] ||
        ce[:dedupe_key] ||
        ce["command_id"] ||
        ce[:command_id]

    case top do
      nil ->
        data = ce["data"] || ce[:data] || %{}
        data["trigger_id"] || data[:trigger_id] || data["id"] || data[:id]

      value ->
        value
    end
  end
end
