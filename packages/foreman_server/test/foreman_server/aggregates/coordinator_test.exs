defmodule ForemanServer.Aggregates.CoordinatorTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.Coordinator
  alias ForemanServer.Aggregates.Coordinator.State
  alias ForemanServer.EventCodec

  @p "proj-1"

  defp cmd(type, payload), do: %{type: type, payload: Map.put_new(payload, :project_id, @p)}

  # Decide a command and apply its event, like the Actor does.
  defp run(state, type, payload) do
    case Coordinator.handle_command(state, cmd(type, payload)) do
      {:ok, nil} -> {:noop, state}
      {:ok, spec} -> {spec, Coordinator.apply_event(state, spec)}
      other -> other
    end
  end

  defp ok!(state, type, payload) do
    {%{} = spec, state} = run(state, type, payload)
    {spec, state}
  end

  defp operator_message(state, id, text \\ "fix the login bug"),
    do: ok!(state, "coordinator.message", %{message_id: id, text: text, source: "cli"})

  defp start_turn(state, turn_id, attempt \\ 1),
    do:
      ok!(state, "coordinator.turn.start", %{
        turn_id: turn_id,
        attempt: attempt,
        trigger_message_ids: ["m1"]
      })

  describe "coordinator.message" do
    test "appends exactly one operator message on the project stream" do
      {spec, _} = operator_message(Coordinator.initial_state(), "m1")
      assert spec.stream_id == "coordinator:proj-1"
      assert spec.event_type == "CoordinatorMessageAppended"
      assert %{role: "operator", kind: "message", source: "cli", message_id: "m1"} = spec.payload
    end

    test "the same message_id twice emits nothing the second time" do
      {_, state} = operator_message(Coordinator.initial_state(), "m1")

      assert {:noop, ^state} =
               run(state, "coordinator.message", %{message_id: "m1", text: "again", source: "cli"})
    end

    test "text and source validation return distinct errors" do
      s = Coordinator.initial_state()

      assert {:error, {:missing_or_invalid, :text}} =
               run(s, "coordinator.message", %{message_id: "m", text: "  "})

      assert {:error, {:missing_or_invalid, :message_id}} =
               run(s, "coordinator.message", %{text: "x"})

      assert {:error, {:invalid_source, "pigeon"}} =
               run(s, "coordinator.message", %{message_id: "m", text: "x", source: "pigeon"})

      too_big = String.duplicate("a", Coordinator.max_message_bytes() + 1)
      max = Coordinator.max_message_bytes()

      assert {:error, {:message_too_large, size, ^max}} =
               run(s, "coordinator.message", %{message_id: "m", text: too_big})

      assert size == max + 1
    end
  end

  describe "coordinator.append" do
    test "rejects an operator role and an unknown kind distinctly" do
      s = Coordinator.initial_state()
      base = %{message_id: "r1", text: "hi", role: "coordinator", kind: "reply"}

      assert {:error, {:invalid_role, "operator"}} =
               run(s, "coordinator.append", %{base | role: "operator"})

      assert {:error, {:missing_or_invalid, :role}} =
               run(s, "coordinator.append", Map.delete(base, :role))

      assert {:error, {:invalid_kind, "poem"}} =
               run(s, "coordinator.append", %{base | kind: "poem"})
    end

    test "a second append with a seen report_key emits nothing, even with a new message_id" do
      s = Coordinator.initial_state()

      rpt = %{
        message_id: "r1",
        text: "verdict met",
        role: "system",
        kind: "report",
        report_key: "ReviewRecorded:run-1"
      }

      {_, s} = ok!(s, "coordinator.append", rpt)
      assert {:noop, _} = run(s, "coordinator.append", %{rpt | message_id: "r2"})
    end
  end

  describe "turns" do
    test "start while a turn is open is rejected; complete clears the open turn and failures" do
      {_, s} = start_turn(Coordinator.initial_state(), "t1")
      assert %State{open_turn: %{turn_id: "t1"}, status: :turn_open} = s

      assert {:error, {:turn_already_open, "t1"}} =
               run(s, "coordinator.turn.start", %{turn_id: "t2", attempt: 1})

      {_, s} = ok!(s, "coordinator.turn.complete", %{turn_id: "t1", cursor_message_id: "m1"})

      assert %State{
               open_turn: nil,
               status: :idle,
               last_cursor_message_id: "m1",
               consecutive_failures: 0
             } = s
    end

    test "action.record needs the matching open turn and a known status" do
      s = Coordinator.initial_state()
      rec = %{turn_id: "t1", action_id: "a1", kind: "answer", status: "executed"}
      assert {:error, {:turn_not_open, "t1"}} = run(s, "coordinator.action.record", rec)

      {_, s} = start_turn(s, "t1")

      assert {:error, {:turn_not_open, "other"}} =
               run(s, "coordinator.action.record", %{rec | turn_id: "other"})

      assert {:error, {:invalid_action_status, "done"}} =
               run(s, "coordinator.action.record", %{rec | status: "done"})

      assert {%{payload: %{status: "executed", params: %{}}}, _} =
               ok!(s, "coordinator.action.record", rec)
    end

    test "three consecutive failures make the coordinator unhealthy; restart clears it; complete resets the count" do
      s = Coordinator.initial_state()

      s =
        Enum.reduce(1..3, s, fn n, s ->
          {_, s} = start_turn(s, "t#{n}", n)

          {_, s} =
            ok!(s, "coordinator.turn.fail", %{
              turn_id: "t#{n}",
              attempt: n,
              error_code: "provider_down"
            })

          s
        end)

      assert %State{status: :unhealthy, consecutive_failures: 3, open_turn: nil} = s

      assert {:error, :coordinator_unhealthy} =
               run(s, "coordinator.turn.start", %{turn_id: "t4", attempt: 1})

      {%{event_type: "CoordinatorRestarted"}, s} = ok!(s, "coordinator.restart", %{by: "op"})
      assert %State{status: :idle, consecutive_failures: 0} = s

      # two failures then a success: the counter resets and never reaches the threshold
      {_, s} = start_turn(s, "t5")
      {_, s} = ok!(s, "coordinator.turn.fail", %{turn_id: "t5", attempt: 1, error_code: "x"})
      {_, s} = start_turn(s, "t6")
      {_, s} = ok!(s, "coordinator.turn.complete", %{turn_id: "t6", cursor_message_id: "m1"})
      assert %State{consecutive_failures: 0, status: :idle} = s
    end

    test "the failure threshold in the command is honoured" do
      {_, s} = start_turn(Coordinator.initial_state(), "t1")

      {_, s} =
        ok!(s, "coordinator.turn.fail", %{
          turn_id: "t1",
          attempt: 1,
          error_code: "x",
          unhealthy_after: 1
        })

      assert %State{status: :unhealthy} = s
    end
  end

  test "the seen-message set is bounded: the oldest id is forgotten after 1000" do
    s =
      Enum.reduce(1..1001, Coordinator.initial_state(), fn n, s ->
        {_, s} = operator_message(s, "m#{n}")
        s
      end)

    assert MapSet.size(s.seen_message_ids) == 1000
    refute MapSet.member?(s.seen_message_ids, "m1")
    assert MapSet.member?(s.seen_message_ids, "m1001")
  end

  test "apply_event ignores event types it does not know and unrelated commands are unhandled" do
    s = Coordinator.initial_state()

    assert s ==
             Coordinator.apply_event(s, %{
               event_type: "SomeFutureEvent",
               payload: %{project_id: @p}
             })

    assert :unhandled = Coordinator.handle_command(s, %{type: "nope", payload: %{}})
  end

  test "all six events are registered with the codec and the router knows the prefix" do
    for type <- ~w(CoordinatorMessageAppended CoordinatorTurnStarted CoordinatorActionRecorded
                   CoordinatorTurnCompleted CoordinatorTurnFailed CoordinatorRestarted) do
      assert type in EventCodec.registered()
    end

    assert ForemanServer.CommandRouter.aggregate_module_for("coordinator:p") == Coordinator
  end
end
