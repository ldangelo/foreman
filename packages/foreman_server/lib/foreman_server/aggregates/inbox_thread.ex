defmodule ForemanServer.Aggregates.InboxThread do
  @moduledoc "Inbox/mail-thread aggregate: validates message append, delivery updates, and dedupe."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate
  alias ForemanServer.Events.{InboxItemStarted, InboxItemDeduped}

  # ─── State ────────────────────────────────────────────────────────────────
  # messages: %{message_id => payload} — existing mail-thread entries
  # correlation_index: %{correlation_id => timestamp} — dedupe lookups
  defmodule State do
    defstruct [:messages, :correlation_index]

    @type t :: %__MODULE__{
            messages: %{optional(String.t()) => map()},
            correlation_index: %{optional(String.t()) => DateTime.t()}
          }
  end

  @impl true
  def initial_state, do: %State{messages: %{}, correlation_index: %{}}

  # ─── apply_event — typed struct clauses ──────────────────────────────────
  # Unwrap %ForemanServer.Event{payload: %TypedEvent{}} produced by decode_for_fold
  @impl true
  def apply_event(state, %ForemanServer.Event{payload: %InboxItemStarted{} = e}) do
    apply_event(state, e)
  end

  def apply_event(state, %ForemanServer.Event{payload: %InboxItemDeduped{} = e}) do
    apply_event(state, e)
  end

  # Direct typed struct (used in tests)
  @impl true
  def apply_event(state, %InboxItemStarted{} = event) do
    %State{
      state
      | messages:
          Map.put(state.messages, event.correlation_id, %{
            correlation_id: event.correlation_id,
            source: event.source,
            payload: event.payload,
            timestamp: event.timestamp
          }),
        correlation_index: Map.put(state.correlation_index, event.correlation_id, event.timestamp)
    }
  end

  def apply_event(state, %InboxItemDeduped{} = event) do
    %State{
      state
      | correlation_index: Map.put(state.correlation_index, event.correlation_id, event.timestamp)
    }
  end

  # Legacy plain-map payload path (existing events from Postgres, or unknown types)
  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "InboxItemStarted" ->
        # Payload is a plain map at this point (decode_for_fold already consumed typed struct)
        # Reconstruct from map for migration path
        message_id = Aggregate.get(payload, :correlation_id)
        ts = Map.get(payload, :timestamp) || DateTime.utc_now()

        %State{
          state
          | messages: Map.put(state.messages, message_id, payload),
            correlation_index: Map.put(state.correlation_index, message_id, ts)
        }

      "InboxItemDeduped" ->
        correlation_id = Aggregate.get(payload, :correlation_id)
        ts = Map.get(payload, :timestamp) || DateTime.utc_now()
        %State{state | correlation_index: Map.put(state.correlation_index, correlation_id, ts)}

      "InboxMessageAppended" ->
        message_id = Aggregate.get(payload, :message_id)
        %State{state | messages: Map.put(state.messages, message_id, payload)}

      "InboxDeliveryUpdated" ->
        message_id = Aggregate.get(payload, :message_id)
        existing = Map.get(state.messages, message_id, %{message_id: message_id})

        %State{
          state
          | messages: Map.put(state.messages, message_id, Map.merge(existing, payload))
        }

      _ ->
        state
    end
  end

  # ─── handle_command ──────────────────────────────────────────────────────
  @impl true
  def handle_command(state, %{type: "inbox.item.start", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, correlation_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :correlation_id), :correlation_id),
         {:ok, source} <- Aggregate.required_binary(Aggregate.get(payload, :source), :source) do
      now = Map.get(payload, :timestamp) || DateTime.utc_now()

      case dedupe_decision(state, correlation_id, now) do
        :duplicate ->
          {:ok,
           %{
             stream_id: "inbox:#{run_id}",
             event_type: "InboxItemDeduped",
             payload: %{correlation_id: correlation_id, source: source, timestamp: now}
           }}

        :accept ->
          item_payload = Aggregate.get(payload, :payload, %{})

          {:ok,
           %{
             stream_id: "inbox:#{run_id}",
             event_type: "InboxItemStarted",
             payload: %{
               correlation_id: correlation_id,
               source: source,
               payload: item_payload,
               timestamp: now
             }
           }}
      end
    end
  end

  def handle_command(state, %{type: "inbox.send", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, message_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :message_id), :message_id),
         {:ok, body} <- Aggregate.required_binary(Aggregate.get(payload, :body), :body),
         :ok <- require_absent(state, message_id) do
      {:ok,
       %{
         stream_id: "inbox:#{run_id}",
         event_type: "InboxMessageAppended",
         payload: Map.merge(payload, %{run_id: run_id, message_id: message_id, body: body})
       }}
    end
  end

  def handle_command(state, %{type: "inbox.delivery.update", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, message_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :message_id), :message_id),
         {:ok, status} <-
           Aggregate.required_binary(Aggregate.get(payload, :delivery_status), :delivery_status),
         :ok <- require_message(state, message_id) do
      {:ok,
       %{
         stream_id: "inbox:#{run_id}",
         event_type: "InboxDeliveryUpdated",
         payload:
           Map.merge(payload, %{run_id: run_id, message_id: message_id, delivery_status: status})
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  # ─── Dedupe ──────────────────────────────────────────────────────────────
  defp dedupe_decision(state, correlation_id, now) do
    window_seconds = dedupe_window_seconds()
    cutoff = DateTime.add(now, -window_seconds, :second)

    case Map.fetch(state.correlation_index, correlation_id) do
      {:ok, last_seen} ->
        if DateTime.compare(last_seen, cutoff) == :gt, do: :duplicate, else: :accept

      :error ->
        :accept
    end
  end

  defp dedupe_window_seconds do
    Application.get_env(:foreman_server, :inbox_dedupe_window_seconds, 300)
  end

  # ─── Helpers ──────────────────────────────────────────────────────────────
  defp require_absent(%State{messages: messages}, message_id) do
    if Map.has_key?(messages, message_id),
      do: {:error, {:already_exists, :message, message_id}},
      else: :ok
  end

  defp require_message(%State{messages: messages}, message_id) do
    if Map.has_key?(messages, message_id),
      do: :ok,
      else: {:error, {:not_found, :message, message_id}}
  end
end
