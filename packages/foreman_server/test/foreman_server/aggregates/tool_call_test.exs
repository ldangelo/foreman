defmodule ForemanServer.Aggregates.ToolCallTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.ToolCall
  alias ForemanServer.CommandRouter
  alias ForemanServer.EventCodec

  alias ForemanServer.Events.{
    ToolCallApproved,
    ToolCallDenied,
    ToolCallExpired,
    ToolCallFinished,
    ToolCallRequested
  }

  @base %{run_id: "r-1", tool_call_id: "tc-1"}

  defp command(type, payload \\ %{}),
    do: %{type: type, payload: Map.merge(@base, payload)}

  # Folds `types` through the aggregate the way the router does after a commit.
  defp state_after(types) do
    Enum.reduce(types, ToolCall.initial_state(), fn type, state ->
      {:ok, spec} = ToolCall.handle_command(state, command(type, %{tool_name: "Write"}))
      ToolCall.apply_event(state, %{event_type: spec.event_type, payload: spec.payload})
    end)
  end

  test "the tool_call: prefix resolves to this aggregate" do
    assert CommandRouter.aggregate_module_for(ToolCall.stream_id("r", "t")) == ToolCall
  end

  test "request emits ToolCallRequested with a redacted, bounded summary" do
    secret = "token=abcd1234secretvalue " <> String.duplicate("x", 900)

    assert {:ok, spec} =
             ToolCall.handle_command(
               ToolCall.initial_state(),
               command("tool.request", %{tool_name: "Bash", input_summary: secret})
             )

    assert spec.stream_id == "tool_call:r-1:tc-1"
    assert spec.event_type == "ToolCallRequested"
    refute spec.payload.input_summary =~ "abcd1234secretvalue"
    assert String.length(spec.payload.input_summary) <= 500
  end

  test "request again for the same ids is rejected" do
    state = state_after(["tool.request"])

    assert {:error, :tool_call_already_requested} =
             ToolCall.handle_command(state, command("tool.request", %{tool_name: "Write"}))
  end

  test "request needs a tool_name and an id" do
    assert {:error, {:missing_or_invalid, :tool_name}} =
             ToolCall.handle_command(ToolCall.initial_state(), command("tool.request"))

    assert {:error, {:missing_or_invalid, :tool_call_id}} =
             ToolCall.handle_command(ToolCall.initial_state(), %{
               type: "tool.request",
               payload: %{run_id: "r", tool_name: "x"}
             })
  end

  test "approve and deny require a requested call" do
    assert {:error, :tool_call_not_requested} =
             ToolCall.handle_command(ToolCall.initial_state(), command("tool.approve"))

    requested = state_after(["tool.request"])

    assert {:ok, %{event_type: "ToolCallApproved"}} =
             ToolCall.handle_command(requested, command("tool.approve"))

    assert {:ok, %{event_type: "ToolCallDenied"}} =
             ToolCall.handle_command(requested, command("tool.deny"))
  end

  test "approve from approved is an invalid status; after deny it is terminal" do
    approved = state_after(["tool.request", "tool.approve"])

    assert {:error, {:invalid_tool_call_status, "approved"}} =
             ToolCall.handle_command(approved, command("tool.approve"))

    denied = state_after(["tool.request", "tool.deny"])

    assert {:error, {:tool_call_terminal, "denied"}} =
             ToolCall.handle_command(denied, command("tool.approve"))
  end

  test "expire only from requested, and an expired call can never be approved" do
    assert {:ok, %{event_type: "ToolCallExpired"}} =
             ToolCall.handle_command(state_after(["tool.request"]), command("tool.expire"))

    approved = state_after(["tool.request", "tool.approve"])

    assert {:error, {:invalid_tool_call_status, "approved"}} =
             ToolCall.handle_command(approved, command("tool.expire"))

    expired = state_after(["tool.request", "tool.expire"])

    assert {:error, {:tool_call_terminal, "expired"}} =
             ToolCall.handle_command(expired, command("tool.approve"))
  end

  test "finish only from requested or approved" do
    approved = state_after(["tool.request", "tool.approve"])

    assert {:ok, %{event_type: "ToolCallFinished"}} =
             ToolCall.handle_command(approved, command("tool.finish"))

    denied = state_after(["tool.request", "tool.deny"])

    assert {:error, {:tool_call_terminal, "denied"}} =
             ToolCall.handle_command(denied, command("tool.finish"))
  end

  test "reason longer than 500 chars is rejected" do
    requested = state_after(["tool.request"])

    assert {:error, {:reason_too_long, 501}} =
             ToolCall.handle_command(
               requested,
               command("tool.deny", %{reason: String.duplicate("a", 501)})
             )
  end

  test "stream ids escape colons so distinct id pairs never collide" do
    refute ToolCall.stream_id("a:b", "c") == ToolCall.stream_id("a", "b:c")
    assert ToolCall.stream_id("a:b", "c") == "tool_call:a%3Ab:c"
  end

  test "every emitted payload round-trips through the EventCodec" do
    for type <- ["tool.request", "tool.approve", "tool.deny", "tool.expire", "tool.finish"] do
      state =
        if type == "tool.request",
          do: ToolCall.initial_state(),
          else: state_after(["tool.request"])

      {:ok, spec} = ToolCall.handle_command(state, command(type, %{tool_name: "Write"}))
      decoded = EventCodec.decode!(spec.event_type, spec.payload)

      assert decoded.__struct__ in [
               ToolCallRequested,
               ToolCallApproved,
               ToolCallDenied,
               ToolCallExpired,
               ToolCallFinished
             ]

      assert decoded.run_id == "r-1"
    end
  end

  test "unknown event types and commands are tolerated" do
    state = ToolCall.initial_state()
    assert ToolCall.apply_event(state, %{event_type: "Nope", payload: %{}}) == state
    assert ToolCall.handle_command(state, %{type: "tool.other", payload: %{}}) == :unhandled
  end
end
