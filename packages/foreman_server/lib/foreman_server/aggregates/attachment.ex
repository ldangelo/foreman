defmodule ForemanServer.Aggregates.Attachment do
  @moduledoc "Attachment aggregate: validates attach request lifecycle per run/worker target."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  defmodule State do
    @enforce_keys [:requested?, :terminal?, :status, :run_id, :worker_id]
    defstruct [:requested?, :terminal?, :status, :run_id, :worker_id]
  end

  @impl true
  def initial_state do
    %State{
      requested?: false,
      terminal?: false,
      status: nil,
      run_id: nil,
      worker_id: nil
    }
  end

  @impl true
  def apply_event(%State{} = state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "AttachRequested" ->
        %State{
          state
          | requested?: true,
            status: "requested",
            run_id: Aggregate.get(payload, :run_id),
            worker_id: Aggregate.get(payload, :worker_id)
        }

      "AttachUnsupported" ->
        %State{
          state
          | terminal?: true,
            status: "unsupported",
            run_id: Aggregate.get(payload, :run_id),
            worker_id: Aggregate.get(payload, :worker_id)
        }

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

  defp require_open(%State{terminal?: true}), do: {:error, :attachment_terminal}
  defp require_open(_state), do: :ok

  defp reject_requested(%State{requested?: true}), do: {:error, :attachment_already_requested}
  defp reject_requested(_state), do: :ok

  defp escape(value), do: String.replace(value, ":", "%3A")
end
