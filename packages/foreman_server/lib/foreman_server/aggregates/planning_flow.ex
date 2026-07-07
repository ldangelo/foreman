defmodule ForemanServer.Aggregates.PlanningFlow do
  @moduledoc "Planning flow aggregate: validates planning lifecycle commands."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  @impl true
  def initial_state do
    %{
      exists?: false,
      completed?: false,
      commands: [],
      traces: %{}
    }
  end

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "PlanningFlowStarted" ->
        state
        |> Map.merge(payload)
        |> Map.put(:exists?, true)
        |> Map.put(:completed?, false)

      "PlanningFlowCommand" ->
        update_in(state.commands, &((&1 || []) ++ [payload]))

      "PlanningTraceLinked" ->
        trace_id = Aggregate.get(payload, :traceability_key) || Aggregate.get(payload, :phase_id)
        put_in(state.traces[trace_id], payload)

      "PlanningFlowCompleted" ->
        state
        |> Map.merge(payload)
        |> Map.put(:exists?, true)
        |> Map.put(:completed?, true)

      _ ->
        state
    end
  end

  @impl true
  def handle_command(state, %{type: type, payload: payload})
      when type in ["planning.start", "PlanningFlowCommand", "plan.prd", "plan.trd"] do
    with {:ok, flow_id} <- flow_id(payload),
         :ok <- require_absent(state) do
      {:ok,
       %{
         stream_id: "planning:#{escape(flow_id)}",
         event_type: "PlanningFlowStarted",
         payload: Map.put(payload, :flow_id, flow_id)
       }}
    end
  end

  def handle_command(state, %{type: "planning.command", payload: payload}) do
    with {:ok, flow_id} <- flow_id(payload),
         :ok <- require_active(state) do
      {:ok,
       %{
         stream_id: "planning:#{escape(flow_id)}",
         event_type: "PlanningFlowCommand",
         payload: Map.put(payload, :flow_id, flow_id)
       }}
    end
  end

  def handle_command(state, %{type: "planning.trace.link", payload: payload}) do
    with {:ok, flow_id} <- flow_id(payload),
         :ok <- require_active(state) do
      {:ok,
       %{
         stream_id: "planning:#{escape(flow_id)}",
         event_type: "PlanningTraceLinked",
         payload: Map.put(payload, :flow_id, flow_id)
       }}
    end
  end

  def handle_command(state, %{type: "planning.complete", payload: payload}) do
    with {:ok, flow_id} <- flow_id(payload),
         :ok <- require_active(state) do
      {:ok,
       %{
         stream_id: "planning:#{escape(flow_id)}",
         event_type: "PlanningFlowCompleted",
         payload: Map.put(payload, :flow_id, flow_id)
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp flow_id(payload) do
    payload
    |> first_present([:flow_id, :run_id, :planning_run_id, :command_id])
    |> Aggregate.required_binary(:flow_id)
  end

  defp first_present(payload, keys) do
    Enum.find_value(keys, &Aggregate.get(payload, &1))
  end

  defp require_absent(%{exists?: true}), do: {:error, :planning_flow_already_started}
  defp require_absent(_state), do: :ok

  defp require_active(%{exists?: false}), do: {:error, :planning_flow_not_started}
  defp require_active(%{completed?: true}), do: {:error, :planning_flow_completed}
  defp require_active(_state), do: :ok

  defp escape(value), do: String.replace(value, ":", "%3A")
end
