defmodule ForemanServer.Aggregates.InboxThread do
  @moduledoc """
  Per-run operator inbox thread aggregate.

  Handles `inbox.send` (append a message) and `inbox.delivery.update`
  (update delivery status). Messages are stored keyed by `message_id`
  so the same message cannot be sent twice (idempotent).

  Stream id: `"inbox:<run_id>"`
  """

  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate
  alias ForemanServer.Events.{InboxMessageAppended, InboxDeliveryUpdated}

  defmodule Message do
    @moduledoc "A message in the thread, keyed by message_id."
    defstruct [:message_id, :body, :delivery_status, metadata: %{}]
  end

  defmodule State do
    @enforce_keys [:messages]
    defstruct [:messages]
  end

  @impl true
  def initial_state, do: %State{messages: %{}}

  @impl true
  def apply_event(state, %InboxMessageAppended{} = event) do
    message = %Message{
      message_id: event.message_id,
      body: event.body,
      metadata: event.metadata
    }

    %State{state | messages: Map.put(state.messages, event.message_id, message)}
  end

  def apply_event(state, %InboxDeliveryUpdated{} = event) do
    updated_message =
      case Map.fetch(state.messages, event.message_id) do
        {:ok, existing} ->
          %Message{
            existing
            | delivery_status: event.delivery_status,
              metadata: Map.merge(existing.metadata, event.metadata)
          }

        :error ->
          %Message{
            message_id: event.message_id,
            delivery_status: event.delivery_status,
            metadata: event.metadata
          }
      end

    %State{state | messages: Map.put(state.messages, event.message_id, updated_message)}
  end

  def apply_event(state, event) do
    # Handle raw map events from event store replay (string keys)
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "InboxMessageAppended" ->
        message_id = Aggregate.get(payload, :message_id) || Aggregate.get(payload, "message_id")
        body = Aggregate.get(payload, :body) || Aggregate.get(payload, "body")
        metadata = Aggregate.get(payload, :metadata) || Aggregate.get(payload, "metadata") || %{}

        message = %Message{message_id: message_id, body: body, metadata: metadata}
        %State{state | messages: Map.put(state.messages, message_id, message)}

      "InboxDeliveryUpdated" ->
        message_id = Aggregate.get(payload, :message_id) || Aggregate.get(payload, "message_id")
        status = Aggregate.get(payload, :delivery_status) || Aggregate.get(payload, "delivery_status")
        metadata = Aggregate.get(payload, :metadata) || Aggregate.get(payload, "metadata") || %{}

        updated_message = %Message{
          message_id: message_id,
          delivery_status: status,
          metadata: metadata
        }

        %State{state | messages: Map.put(state.messages, message_id, updated_message)}

      _ ->
        state
    end
  end

  @impl true
  def handle_command(state, %{type: "inbox.send", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id) || Aggregate.get(payload, "run_id"), :run_id),
         {:ok, message_id} <- Aggregate.required_binary(Aggregate.get(payload, :message_id) || Aggregate.get(payload, "message_id"), :message_id),
         {:ok, body} <- Aggregate.required_binary(Aggregate.get(payload, :body) || Aggregate.get(payload, "body"), :body),
         :ok <- require_absent(state, message_id) do
      metadata = Aggregate.get(payload, :metadata) || Aggregate.get(payload, "metadata") || %{}

      {:ok,
       %InboxMessageAppended{
         run_id: run_id,
         message_id: message_id,
         body: body,
         metadata: metadata
       }}
    end
  end

  def handle_command(state, %{type: "inbox.delivery.update", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id) || Aggregate.get(payload, "run_id"), :run_id),
         {:ok, message_id} <- Aggregate.required_binary(Aggregate.get(payload, :message_id) || Aggregate.get(payload, "message_id"), :message_id),
         {:ok, status} <- Aggregate.required_binary(Aggregate.get(payload, :delivery_status) || Aggregate.get(payload, "delivery_status"), :delivery_status),
         :ok <- require_message(state, message_id) do
      metadata = Aggregate.get(payload, :metadata) || Aggregate.get(payload, "metadata") || %{}

      {:ok,
       %InboxDeliveryUpdated{
         run_id: run_id,
         message_id: message_id,
         delivery_status: status,
         metadata: metadata
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

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
