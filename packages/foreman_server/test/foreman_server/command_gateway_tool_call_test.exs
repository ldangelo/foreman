defmodule ForemanServer.CommandGatewayToolCallTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.ToolCall
  alias ForemanServer.{CommandGateway, EventStore}

  defp uid, do: Elixir.EventStore.UUID.uuid4()

  defp request(run_id, tool_call_id) do
    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "tool.request",
        command_id: "tool-request:#{uid()}",
        aggregate_id: ToolCall.stream_id(run_id, tool_call_id),
        payload: %{run_id: run_id, tool_call_id: tool_call_id, tool_name: "Write"}
      })
  end

  defp operator(type, run_id, tool_call_id, overrides \\ %{}) do
    Map.merge(
      %{
        type: type,
        command_id: "op-#{uid()}",
        aggregate_id: ToolCall.stream_id(run_id, tool_call_id),
        payload: %{run_id: run_id, tool_call_id: tool_call_id}
      },
      overrides
    )
  end

  test "an operator approves a requested call; decided_at/decided_by are stamped server-side" do
    run_id = "run-#{uid()}"
    request(run_id, "tc-1")

    assert {:ok, _} =
             CommandGateway.dispatch_operator(
               operator("tool.approve", run_id, "tc-1", %{
                 payload: %{
                   run_id: run_id,
                   tool_call_id: "tc-1",
                   decided_at: "1999-01-01T00:00:00Z"
                 }
               })
             )

    {:ok, events} = EventStore.read_stream_forward(ToolCall.stream_id(run_id, "tc-1"), 0, 100)
    assert Enum.map(events, & &1.event_type) == ["ToolCallRequested", "ToolCallApproved"]
    approved = List.last(events).data
    refute to_string(approved["decided_at"] || approved[:decided_at]) =~ "1999"
    assert (approved["decided_by"] || approved[:decided_by]) == "operator"
  end

  test "approving a call that was never requested is a domain error" do
    assert {:error, :tool_call_not_requested} =
             CommandGateway.dispatch_operator(operator("tool.approve", "run-#{uid()}", "tc-x"))
  end

  test "system-only tool commands are refused on the operator path" do
    for type <- ["tool.request", "tool.finish", "tool.expire"] do
      assert {:error, {:command_not_allowed, ^type}} =
               CommandGateway.dispatch_operator(operator(type, "r", "t"))
    end
  end

  test "the aggregate id must be the composite tool_call stream" do
    assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
             CommandGateway.dispatch_operator(
               operator("tool.deny", "r", "t", %{aggregate_id: "run:r"})
             )
  end

  test "tool.approve can never reach a run's merge gate" do
    run_id = "run-#{uid()}"

    assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
             CommandGateway.dispatch_operator(
               operator("tool.approve", run_id, "t", %{aggregate_id: "run:#{run_id}"})
             )

    assert {:error, {:command_not_allowed, "tool.approve_merge"}} =
             CommandGateway.dispatch_operator(operator("tool.approve_merge", run_id, "t"))
  end

  test "repeating the same command_id is idempotent: one decision event" do
    run_id = "run-#{uid()}"
    request(run_id, "tc-1")
    command = operator("tool.deny", run_id, "tc-1")

    assert {:ok, first} = CommandGateway.dispatch_operator(command)
    assert {:ok, replay} = CommandGateway.dispatch_operator(command)
    assert replay == ForemanServer.Aggregate.Actor.mark_replayed(first)

    {:ok, events} = EventStore.read_stream_forward(ToolCall.stream_id(run_id, "tc-1"), 0, 100)
    assert Enum.count(events, &(&1.event_type == "ToolCallDenied")) == 1
  end
end
