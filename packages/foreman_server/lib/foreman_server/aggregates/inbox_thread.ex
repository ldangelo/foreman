defmodule ForemanServer.Aggregates.InboxThread do
  @moduledoc "Inbox/mail-thread aggregate: validates message append and delivery updates."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  @impl true
  def initial_state, do: %{messages: %{}}

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "InboxMessageAppended" ->
        message_id = Aggregate.get(payload, :message_id)
        put_in(state, [:messages, message_id], payload)

      "InboxDeliveryUpdated" ->
        message_id = Aggregate.get(payload, :message_id)

        update_in(
          state,
          [:messages, message_id],
          &Map.merge(&1 || %{message_id: message_id}, payload)
        )

      _ ->
        state
    end
  end

  @impl true
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

  defp require_absent(%{messages: messages}, message_id) do
    if Map.has_key?(messages, message_id),
      do: {:error, {:already_exists, :message, message_id}},
      else: :ok
  end

  defp require_message(%{messages: messages}, message_id) do
    if Map.has_key?(messages, message_id),
      do: :ok,
      else: {:error, {:not_found, :message, message_id}}
  end
end
