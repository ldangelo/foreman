defmodule ForemanServer.Approvals.RequesterTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.ToolCall
  alias ForemanServer.Approvals.Requester
  alias ForemanServer.EventStore

  defp run_id, do: "run-req-#{System.unique_integer([:positive])}"

  defp events(run_id, id) do
    {:ok, events} = EventStore.read_stream_forward(ToolCall.stream_id(run_id, id), 0, 100)
    events
  end

  test "asking twice for the same tool call appends exactly one ToolCallRequested" do
    run_id = run_id()
    ctx = %{run_id: run_id, project_id: "p", provider: :claude}

    assert {:ok, "perm-1-Write"} =
             Requester.request(ctx, "Write", %{"path" => "a"}, phase_index: 1)

    assert {:ok, "perm-1-Write"} =
             Requester.request(ctx, "Write", %{"path" => "a"}, phase_index: 1)

    assert [%{event_type: "ToolCallRequested"}] = events(run_id, "perm-1-Write")
  end

  test "the request records the provider's delivery mode" do
    run_id = run_id()

    {:ok, id} = Requester.request(%{run_id: run_id, provider: :opencode}, "Bash", "ls", [])
    [%{data: live}] = events(run_id, id)
    assert (live["delivery"] || live[:delivery]) == "live"

    run_id = run_id()
    {:ok, id} = Requester.request(%{run_id: run_id, provider: :pi}, "Bash", "ls", [])
    [%{data: resume}] = events(run_id, id)
    assert (resume["delivery"] || resume[:delivery]) == "resume_with_override"
  end

  test "a secret in the tool input is never stored and the summary is bounded" do
    run_id = run_id()

    input = %{
      "command" => "curl",
      "api_key" => "sk-super-secret-value",
      "pad" => String.duplicate("x", 5_000)
    }

    {:ok, id} = Requester.request(%{run_id: run_id}, "Bash", input, [])

    [%{data: data}] = events(run_id, id)
    summary = data["input_summary"] || data[:input_summary]
    refute summary =~ "sk-super-secret-value"
    assert String.length(summary) <= 500
  end

  test "a gateway refusal is returned, not swallowed" do
    assert {:error, {:missing_or_invalid, :tool_name}} =
             Requester.request(%{run_id: run_id()}, "", "x", tool_call_id: "t")
  end
end
