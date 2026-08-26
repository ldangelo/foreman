defmodule ForemanServer.Aggregates.ToolCall do
  @moduledoc "Tool-call aggregate: validates request, decision, and finish lifecycle."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  defmodule State do
    @enforce_keys [:exists?, :tool_call_id, :status, :terminal?]
    defstruct [:exists?, :tool_call_id, :status, :terminal?]
  end

  @impl true
  def initial_state do
    %State{
      exists?: false,
      tool_call_id: nil,
      status: nil,
      terminal?: false
    }
  end

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "ToolCallRequested" ->
        %State{
          state
          | exists?: true,
            tool_call_id: Aggregate.get(payload, :tool_call_id),
            status: "requested"
        }

      "ToolCallApproved" ->
        %State{
          state
          | exists?: true,
            tool_call_id: Aggregate.get(payload, :tool_call_id),
            status: "approved"
        }

      "ToolCallDenied" ->
        %State{
          state
          | exists?: true,
            tool_call_id: Aggregate.get(payload, :tool_call_id),
            status: "denied",
            terminal?: true
        }

      "ToolCallFinished" ->
        %State{
          state
          | exists?: true,
            tool_call_id: Aggregate.get(payload, :tool_call_id),
            status: "finished",
            terminal?: true
        }

      _ ->
        state
    end
  end

  @impl true
  def handle_command(state, %{type: "tool.request", payload: payload}) do
    with {:ok, tool_call_id} <- tool_call_id(payload),
         :ok <- require_absent(state) do
      {:ok,
       %{
         stream_id: stream_id(payload, tool_call_id),
         event_type: "ToolCallRequested",
         payload: Map.put(payload, :tool_call_id, tool_call_id)
       }}
    end
  end

  def handle_command(state, %{type: type, payload: payload})
      when type in ["tool.approve", "tool.deny"] do
    with {:ok, tool_call_id} <- tool_call_id(payload),
         :ok <- require_status(state, ["requested"]) do
      event_type = if type == "tool.approve", do: "ToolCallApproved", else: "ToolCallDenied"

      {:ok,
       %{
         stream_id: stream_id(payload, tool_call_id),
         event_type: event_type,
         payload: Map.put(payload, :tool_call_id, tool_call_id)
       }}
    end
  end

  def handle_command(state, %{type: "tool.finish", payload: payload}) do
    with {:ok, tool_call_id} <- tool_call_id(payload),
         :ok <- require_status(state, ["requested", "approved"]) do
      {:ok,
       %{
         stream_id: stream_id(payload, tool_call_id),
         event_type: "ToolCallFinished",
         payload: Map.put(payload, :tool_call_id, tool_call_id)
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp tool_call_id(payload) do
    payload
    |> first_present(["tool_call_id", "id", "call_id"])
    |> Aggregate.required_binary(:tool_call_id)
  end

  defp first_present(payload, keys) do
    Enum.find_value(keys, &Aggregate.get(payload, &1))
  end

  defp stream_id(payload, tool_call_id) do
    run_id = Aggregate.get(payload, :run_id, "global") || "global"
    "tool_call:#{escape(run_id)}:#{escape(tool_call_id)}"
  end

  defp require_absent(%State{exists?: true}), do: {:error, :tool_call_already_requested}
  defp require_absent(_state), do: :ok

  defp require_status(%State{terminal?: true, status: status}, _allowed),
    do: {:error, {:tool_call_terminal, status}}

  defp require_status(%State{exists?: false}, _allowed), do: {:error, :tool_call_not_requested}

  defp require_status(%State{status: status}, allowed) do
    if status in allowed, do: :ok, else: {:error, {:invalid_tool_call_status, status}}
  end

  defp escape(value), do: String.replace(value, ":", "%3A")
end
