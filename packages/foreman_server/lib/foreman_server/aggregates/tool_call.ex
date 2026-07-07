defmodule ForemanServer.Aggregates.ToolCall do
  @moduledoc "Tool-call aggregate: validates request, decision, and finish lifecycle."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  @impl true
  def initial_state do
    %{
      exists?: false,
      status: nil,
      terminal?: false
    }
  end

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "ToolCallRequested" ->
        state
        |> Map.merge(payload)
        |> Map.put(:exists?, true)
        |> Map.put(:status, "requested")

      "ToolCallApproved" ->
        state
        |> Map.merge(payload)
        |> Map.put(:exists?, true)
        |> Map.put(:status, "approved")

      "ToolCallDenied" ->
        state
        |> Map.merge(payload)
        |> Map.put(:exists?, true)
        |> Map.put(:status, "denied")
        |> Map.put(:terminal?, true)

      "ToolCallFinished" ->
        state
        |> Map.merge(payload)
        |> Map.put(:exists?, true)
        |> Map.put(:status, "finished")
        |> Map.put(:terminal?, true)

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
         :ok <- require_status(state, ["requested", "approved", "running"]) do
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
    |> first_present([:tool_call_id, :tool_call, :call_id, :id])
    |> Aggregate.required_binary(:tool_call_id)
  end

  defp first_present(payload, keys) do
    Enum.find_value(keys, &Aggregate.get(payload, &1))
  end

  defp stream_id(payload, tool_call_id) do
    case Aggregate.get(payload, :run_id) do
      run_id when is_binary(run_id) and run_id != "" ->
        "tool_call:#{escape(run_id)}:#{escape(tool_call_id)}"

      _ ->
        "tool_call:#{escape(tool_call_id)}"
    end
  end

  defp require_absent(%{exists?: true}), do: {:error, :tool_call_already_requested}
  defp require_absent(_state), do: :ok

  defp require_status(%{terminal?: true, status: status}, _allowed),
    do: {:error, {:tool_call_terminal, status}}

  defp require_status(%{exists?: false}, _allowed), do: {:error, :tool_call_not_requested}

  defp require_status(%{status: status}, allowed) do
    if status in allowed,
      do: :ok,
      else: {:error, {:invalid_tool_call_state, status}}
  end

  defp escape(value), do: String.replace(value, ":", "%3A")
end
