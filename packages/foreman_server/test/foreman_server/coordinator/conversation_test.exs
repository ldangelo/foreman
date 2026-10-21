defmodule ForemanServer.Coordinator.ConversationTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Coordinator.Conversation

  defp msg(conv, id, attrs \\ %{}) do
    payload =
      Map.merge(
        %{
          project_id: "p",
          message_id: id,
          role: "operator",
          kind: "message",
          text: "t-#{id}",
          source: "cli",
          at: "2026-01-01T00:00:00Z"
        },
        attrs
      )

    Conversation.apply_event(conv, "CoordinatorMessageAppended", payload)
  end

  test "seq is monotonic from 1 and string-keyed (replayed) payloads fold identically" do
    atom = Conversation.new() |> msg("a") |> msg("b")

    string =
      Enum.reduce(["a", "b"], Conversation.new(), fn id, conv ->
        payload = %{
          "project_id" => "p",
          "message_id" => id,
          "role" => "operator",
          "kind" => "message",
          "text" => "t-#{id}",
          "source" => "cli",
          "at" => "2026-01-01T00:00:00Z"
        }

        Conversation.apply_event(conv, "CoordinatorMessageAppended", payload)
      end)

    assert Enum.map(atom.messages, & &1.seq) == [1, 2]
    assert atom == string
  end

  test "a malformed payload and an unknown event type leave the conversation unchanged" do
    conv = msg(Conversation.new(), "a")

    assert conv ==
             Conversation.apply_event(conv, "CoordinatorMessageAppended", %{
               project_id: "p",
               message_id: 5,
               text: nil
             })

    assert conv == Conversation.apply_event(conv, "CoordinatorTurnCompleted", %{project_id: "p"})
    assert conv == Conversation.apply_event(conv, "CoordinatorFuture", %{project_id: "p"})
  end

  test "page returns only newer messages, honours the limit and reports has_more and the window start" do
    conv = Enum.reduce(1..5, Conversation.new(), &msg(&2, "m#{&1}"))

    assert %{messages: [%{seq: 3}, %{seq: 4}], next_cursor: 4, has_more: true} =
             Conversation.page(conv, 2, 2)

    assert %{messages: [%{seq: 5}], next_cursor: 5, has_more: false} =
             Conversation.page(conv, 4, 10)

    assert %{messages: [], next_cursor: 5, has_more: false} = Conversation.page(conv, 5, 10)
  end

  test "the window keeps the newest 1000 and says where it starts" do
    conv = Enum.reduce(1..1002, Conversation.new(), &msg(&2, "m#{&1}"))
    assert length(conv.messages) == 1000
    assert conv.truncated_before_seq == 3
    assert %{truncated_before_seq: 3} = Conversation.page(conv, 0, 5)
  end

  test "pending counts operator and unsuppressed report messages after the cursor, not coordinator replies or notices" do
    conv =
      Conversation.new()
      |> msg("op1")
      |> msg("reply", %{role: "coordinator", kind: "reply"})
      |> msg("rep", %{role: "system", kind: "report"})
      |> msg("quiet", %{role: "system", kind: "report", suppressed: true})
      |> msg("note", %{role: "system", kind: "notice"})

    assert Enum.map(Conversation.pending(conv), & &1.message_id) == ["op1", "rep"]

    conv =
      Conversation.apply_event(conv, "CoordinatorTurnStarted", %{
        project_id: "p",
        turn_id: "t",
        attempt: 1
      })

    conv =
      Conversation.apply_event(conv, "CoordinatorTurnCompleted", %{
        project_id: "p",
        turn_id: "t",
        cursor_message_id: "rep"
      })

    assert Conversation.pending(conv) == []
    assert conv.last_cursor_seq == 3
  end

  test "failures mark unhealthy at the threshold, keep the last error, and restart clears both" do
    conv =
      Enum.reduce(1..3, Conversation.new(), fn n, conv ->
        conv =
          Conversation.apply_event(conv, "CoordinatorTurnStarted", %{
            project_id: "p",
            turn_id: "t#{n}",
            attempt: n
          })

        Conversation.apply_event(conv, "CoordinatorTurnFailed", %{
          project_id: "p",
          turn_id: "t#{n}",
          attempt: n,
          error_code: "boom",
          message: "m#{n}",
          unhealthy_after: 3
        })
      end)

    assert Conversation.status(conv) == :unhealthy
    assert %{code: "boom", message: "m3", turn_id: "t3"} = conv.last_error

    conv = Conversation.apply_event(conv, "CoordinatorRestarted", %{project_id: "p"})
    assert Conversation.status(conv) == :idle
    assert conv.last_error == nil
  end

  test "recorded actions are keyed by action id so a later turn can look them up" do
    conv =
      Conversation.apply_event(Conversation.new(), "CoordinatorActionRecorded", %{
        project_id: "p",
        turn_id: "t1",
        action_id: "a1",
        kind: "propose_threads",
        status: "proposed",
        params: %{"threads" => []},
        result_ref: %{"task_ids" => ["x"]}
      })

    assert %{status: "proposed", result_ref: %{"task_ids" => ["x"]}, turn_id: "t1"} =
             conv.actions["a1"]
  end
end
