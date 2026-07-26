defmodule ForemanServer.Aggregates.Attachment do
  @moduledoc "Attachment aggregate: validates attach request lifecycle per run/worker target."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  @impl true
  def initial_state do
    %{
      requested?: false,
      terminal?: false,
      status: nil
    }
  end

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "AttachRequested" ->
        state
        |> Map.merge(payload)
        |> Map.put(:requested?, true)
        |> Map.put(:status, "requested")

      "AttachUnsupported" ->
        state
        |> Map.merge(payload)
        |> Map.put(:terminal?, true)
        |> Map.put(:status, "unsupported")

      _ ->
        state
    end
  end

  @impl true
  def handle_command(state, %{type: "attach.request", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_open(state),
         :ok <- reject_requested(state) do
      {:ok,
       %{
         stream_id: stream_id(payload, run_id),
         event_type: "AttachRequested",
         payload: Map.put(payload, :run_id, run_id)
       }}
    end
  end

  def handle_command(state, %{type: "attach.unsupported", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_open(state) do
      {:ok,
       %{
         stream_id: stream_id(payload, run_id),
         event_type: "AttachUnsupported",
         payload: Map.put(payload, :run_id, run_id)
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp stream_id(payload, run_id) do
    worker_id = Aggregate.get(payload, :worker_id, "default") || "default"
    "attach:#{escape(run_id)}:#{escape(worker_id)}"
  end

  defp require_open(%{terminal?: true}), do: {:error, :attachment_terminal}
  defp require_open(_state), do: :ok

  defp reject_requested(%{requested?: true}), do: {:error, :attachment_already_requested}
  defp reject_requested(_state), do: :ok

  defp escape(value), do: String.replace(value, ":", "%3A")
end
