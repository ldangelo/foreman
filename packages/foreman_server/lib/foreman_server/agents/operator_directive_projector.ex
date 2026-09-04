defmodule ForemanServer.Agents.OperatorDirectiveProjector do
  @moduledoc """
  Foreman-side projector that converts `InboxItemStarted` events
  (source: `OperatorQuestionSource`) into Jido directives published
  on the `agents.<agent_id>.directive` topic
  (TRD-2026-4212be7e, JSI-T008).

  ## Wiring

  1. `attach/1` is called at boot (typically from the supervisor
     that hosts this module) to register the projector as an
     `OperatorQuestionSource` handler on the Inbox Poller.
  2. The Poller calls `handle_info/2` (this module's GenServer
     callback) with each new `InboxItemStarted` event.
  3. `handle_info/2` calls `publish/2`, which builds the
     `agents.<agent_id>.directive` Jido signal and publishes it
     via `SignalDirectivePublisher`.

  This completes the operator-question flow:
    1. Operator UI POSTs to `/webhooks/operator/ingest` (JSI-T007).
    2. `WebhookController.operator_ingest/2` calls
       `OperatorQuestionDispatcher.dispatch/1` (JSI-T007).
    3. The dispatcher calls `SharedInbox.ingest/2`, which writes
       an `InboxItemStarted` event to the Inbox.
    4. **This projector** is the Inbox Poller handler that picks
       up the `InboxItemStarted` event and publishes a Jido signal
       to the agent's directive topic.

  The directive signal's `data` is:

      %{
        "query_id" => inbox.correlation_id,
        "question" => inbox.payload["question"],
        "options"  => inbox.payload["options"] || %{}
      }

  The agent_id is read from the inbox payload (set by
  `OperatorQuestionSource` via the operator question data).
  """

  require Logger

  use GenServer

  alias ForemanServer.Agents.JidoSignalTopics
  alias ForemanServer.Agents.OperatorQuestionSource
  alias ForemanServer.Agents.SignalDirectivePublisher
  alias ForemanServer.Inbox.{InboxItemStarted, Poller}

  ## Public API

  @doc """
  Start the projector as a GenServer. On init, attaches to the
  Inbox Poller so every `InboxItemStarted` event from
  `OperatorQuestionSource` is forwarded to `handle_info/2`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Attach the projector to the Inbox Poller (idempotent — the
  Poller dedupes handler names).
  """
  @spec attach(GenServer.server()) :: :ok | {:error, term()}
  def attach(handler_pid \\ self()) do
    Poller.attach_handler(OperatorQuestionSource, :operator_directive_projector, handler_pid)
  end

  @doc """
  Detach the projector from the Inbox Poller.
  """
  @spec detach() :: :ok
  def detach do
    Poller.detach_handler(OperatorQuestionSource)
    :ok
  end

  @doc """
  Build the `agents.<agent_id>.directive` Jido signal for the given
  InboxItemStarted event.

  Returns `nil` if the event has no `agent_id` in its payload (the
  caller should drop such events).
  """
  @spec build_directive(InboxItemStarted.t()) :: struct() | nil
  def build_directive(%InboxItemStarted{payload: payload} = event) do
    with {:ok, agent_id} <- canonical_field(payload, :agent_id),
         true <- is_binary(agent_id) and agent_id != "",
         {:ok, question} <- canonical_field(payload, :question),
         {:ok, options} <- canonical_field(payload, :options) do
      {:ok, signal} =
        Jido.Signal.new(
          JidoSignalTopics.agent_directive(agent_id),
          %{
            "query_id" => event.correlation_id,
            "question" => question,
            "options" => options || %{}
          },
          source: "foreman.operator_directive_projector"
        )

      signal
    else
      _ ->
        Logger.warning(
          "OperatorDirectiveProjector.build_directive: no agent_id, or conflicting " <>
            "atom/string payload keys, skipping: #{inspect(payload)}"
        )

        nil
    end
  end

  # Read a field that may arrive as either an atom or a string key
  # (Jido's data round-trip is not key-convention-stable). Returns the
  # shared value when only one representation is present or both agree;
  # returns `:error` when both are present with conflicting non-nil
  # values, so a conflicting payload is dropped rather than silently
  # resolved by picking one representation.
  defp canonical_field(payload, atom_key) do
    atom_value = Map.get(payload, atom_key)
    string_value = Map.get(payload, Atom.to_string(atom_key))

    cond do
      is_nil(atom_value) -> {:ok, string_value}
      is_nil(string_value) -> {:ok, atom_value}
      atom_value == string_value -> {:ok, atom_value}
      true -> :error
    end
  end

  @doc """
  Build the directive and publish it on the bus in one call.
  Returns the standard `SignalDirectivePublisher.publish/3` result.
  """
  @spec publish(InboxItemStarted.t(), GenServer.server() | :default) ::
          {:ok, [Jido.Signal.Bus.RecordedSignal.t()]} | {:error, term()} | :skipped
  def publish(%InboxItemStarted{} = event, bus \\ :default) do
    case build_directive(event) do
      nil ->
        :skipped

      %Jido.Signal{} = signal ->
        SignalDirectivePublisher.publish(bus, agent_id_from_signal(signal), signal.data)
    end
  end

  ## GenServer callbacks

  @impl true
  def init(opts) do
    bus = Keyword.get(opts, :bus, :default)

    case attach(self()) do
      :ok ->
        {:ok, %{bus: bus}}

      {:error, _} = err ->
        Logger.warning(
          "OperatorDirectiveProjector.init: failed to attach to Poller: #{inspect(err)}"
        )

        {:stop, {:attach_failed, err}}
    end
  end

  @impl true
  def handle_info(
        {:inbox_item_started, _handler, %InboxItemStarted{} = event},
        %{bus: bus} = state
      ) do
    publish(event, bus)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Internal

  defp agent_id_from_signal(%Jido.Signal{type: type}) do
    # "agents.<agent_id>.directive" → agent_id
    type
    |> String.split(".")
    |> Enum.at(1)
  end
end
