defmodule ForemanServer.Aggregates.PlanningFlowTest do
  @moduledoc """
  TRD-007: PlanningFlow aggregate unit tests.

  Pins the planning lifecycle state transitions:

    * `planning.start` (and aliases `plan.prd` / `plan.trd`) from
      `initial_state/0` emits `PlanningFlowStarted` with deterministic
      stream id `"planning:<flow_id>"`; subsequent starts are rejected with
      `:planning_flow_already_started`.
    * `planning.command` is only valid after start; rejected with
      `:planning_flow_not_started` from `initial_state` and
      `:planning_flow_completed` after completion.
    * `planning.trace.link` records a `traceability_key` -> payload map and
      can be called repeatedly.
    * `planning.complete` from active state emits `PlanningFlowCompleted`;
      re-completing is rejected with `:planning_flow_completed`.
    * `apply_event/2` folds each typed event using `%State{state | ...}`.
    * Stream id is deterministic: `"planning:<flow_id>"` (colons escaped
      in `flow_id` for EventStore compatibility).
  """

  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.PlanningFlow

  defp uuid, do: EventStore.UUID.uuid4()
  defp start_state, do: PlanningFlow.initial_state()

  defp fold(state, event_type, payload) do
    PlanningFlow.apply_event(state, %{event_type: event_type, payload: payload})
  end

  defp started_state do
    flow_id = uuid()

    {:ok, spec} =
      PlanningFlow.handle_command(start_state(), %{
        type: "planning.start",
        payload: %{flow_id: flow_id}
      })

    fold(start_state(), spec.event_type, spec.payload)
  end

  # ---------------------------------------------------------------------------
  # initial_state
  # ---------------------------------------------------------------------------

  test "initial_state has exists?: false, completed?: false" do
    state = PlanningFlow.initial_state()

    assert state.exists? == false
    assert state.completed? == false
    assert state.flow_id == nil
    assert state.commands == []
    assert state.traces == %{}
  end

  # ---------------------------------------------------------------------------
  # planning.start / plan.prd / plan.trd
  # ---------------------------------------------------------------------------

  describe "handle_command/2 — planning.start" do
    test "from initial_state emits PlanningFlowStarted with deterministic stream id" do
      flow_id = uuid()

      assert {:ok, spec} =
               PlanningFlow.handle_command(start_state(), %{
                 type: "planning.start",
                 payload: %{flow_id: flow_id}
               })

      assert spec.event_type == "PlanningFlowStarted"
      assert spec.stream_id == "planning:#{flow_id}"
      assert spec.payload.flow_id == flow_id
    end

    test "rejects missing flow_id with {:missing_or_invalid, :flow_id}" do
      assert {:error, {:missing_or_invalid, :flow_id}} =
               PlanningFlow.handle_command(start_state(), %{
                 type: "planning.start",
                 payload: %{}
               })
    end

    test "rejects start from already-started state" do
      state = started_state()

      assert {:error, :planning_flow_already_started} =
               PlanningFlow.handle_command(state, %{
                 type: "planning.start",
                 payload: %{flow_id: uuid()}
               })
    end

    test "supports plan.prd and plan.trd aliases" do
      for type <- ["plan.prd", "plan.trd", "PlanningFlowCommand"] do
        flow_id = uuid()

        assert {:ok, spec} =
                 PlanningFlow.handle_command(start_state(), %{
                   type: type,
                   payload: %{flow_id: flow_id}
                 })

        assert spec.event_type == "PlanningFlowStarted"
        assert spec.stream_id == "planning:#{flow_id}"
      end
    end

    test "falls back to run_id when flow_id absent" do
      run_id = uuid()

      assert {:ok, spec} =
               PlanningFlow.handle_command(start_state(), %{
                 type: "planning.start",
                 payload: %{run_id: run_id}
               })

      assert spec.event_type == "PlanningFlowStarted"
      assert spec.stream_id == "planning:#{run_id}"
    end

    test "escapes colons in flow_id" do
      flow_id = "abc:def"

      assert {:ok, spec} =
               PlanningFlow.handle_command(start_state(), %{
                 type: "planning.start",
                 payload: %{flow_id: flow_id}
               })

      assert spec.stream_id == "planning:abc%3Adef"
    end
  end

  # ---------------------------------------------------------------------------
  # planning.command
  # ---------------------------------------------------------------------------

  describe "handle_command/2 — planning.command" do
    test "rejects from initial_state with :planning_flow_not_started" do
      assert {:error, :planning_flow_not_started} =
               PlanningFlow.handle_command(start_state(), %{
                 type: "planning.command",
                 payload: %{flow_id: "x", command: "create_prd"}
               })
    end

    test "from active state emits PlanningFlowCommand" do
      state = started_state()
      flow_id = state.flow_id

      assert {:ok, spec} =
               PlanningFlow.handle_command(state, %{
                 type: "planning.command",
                 payload: %{flow_id: flow_id, command: "create_prd"}
               })

      assert spec.event_type == "PlanningFlowCommand"
      assert spec.stream_id == "planning:#{flow_id}"
    end

    test "rejects from completed state" do
      state = started_state()
      flow_id = state.flow_id

      {:ok, done_spec} =
        PlanningFlow.handle_command(state, %{
          type: "planning.complete",
          payload: %{flow_id: flow_id}
        })

      completed = fold(state, done_spec.event_type, done_spec.payload)

      assert {:error, :planning_flow_completed} =
               PlanningFlow.handle_command(completed, %{
                 type: "planning.command",
                 payload: %{flow_id: flow_id, command: "create_prd"}
               })
    end
  end

  # ---------------------------------------------------------------------------
  # planning.trace.link
  # ---------------------------------------------------------------------------

  describe "handle_command/2 — planning.trace.link" do
    test "from active state emits PlanningTraceLinked" do
      state = started_state()
      flow_id = state.flow_id

      assert {:ok, spec} =
               PlanningFlow.handle_command(state, %{
                 type: "planning.trace.link",
                 payload: %{flow_id: flow_id, traceability_key: "REQ-007", phase_id: "p1"}
               })

      assert spec.event_type == "PlanningTraceLinked"
      assert spec.stream_id == "planning:#{flow_id}"
    end

    test "accumulates traces in state" do
      state = started_state()
      flow_id = state.flow_id

      {:ok, spec} =
        PlanningFlow.handle_command(state, %{
          type: "planning.trace.link",
          payload: %{flow_id: flow_id, traceability_key: "REQ-007", phase_id: "p1"}
        })

      next = fold(state, spec.event_type, spec.payload)
      assert Map.has_key?(next.traces, "REQ-007")
      assert next.traces["REQ-007"].phase_id == "p1"
    end

    test "rejects from initial_state with :planning_flow_not_started" do
      assert {:error, :planning_flow_not_started} =
               PlanningFlow.handle_command(start_state(), %{
                 type: "planning.trace.link",
                 payload: %{flow_id: "x", traceability_key: "k"}
               })
    end
  end

  # ---------------------------------------------------------------------------
  # planning.complete
  # ---------------------------------------------------------------------------

  describe "handle_command/2 — planning.complete" do
    test "from active state emits PlanningFlowCompleted" do
      state = started_state()
      flow_id = state.flow_id

      assert {:ok, spec} =
               PlanningFlow.handle_command(state, %{
                 type: "planning.complete",
                 payload: %{flow_id: flow_id}
               })

      assert spec.event_type == "PlanningFlowCompleted"
      assert spec.stream_id == "planning:#{flow_id}"
    end

    test "rejects from initial_state with :planning_flow_not_started" do
      assert {:error, :planning_flow_not_started} =
               PlanningFlow.handle_command(start_state(), %{
                 type: "planning.complete",
                 payload: %{flow_id: "x"}
               })
    end

    test "rejects re-completion with :planning_flow_completed" do
      state = started_state()
      flow_id = state.flow_id

      {:ok, done_spec} =
        PlanningFlow.handle_command(state, %{
          type: "planning.complete",
          payload: %{flow_id: flow_id}
        })

      completed = fold(state, done_spec.event_type, done_spec.payload)

      assert {:error, :planning_flow_completed} =
               PlanningFlow.handle_command(completed, %{
                 type: "planning.complete",
                 payload: %{flow_id: flow_id}
               })
    end
  end

  # ---------------------------------------------------------------------------
  # apply_event
  # ---------------------------------------------------------------------------

  describe "apply_event/2 — typed event fold" do
    test "PlanningFlowStarted marks exists?: true, completed?: false" do
      state = started_state()

      assert state.exists? == true
      assert state.completed? == false
      refute is_nil(state.flow_id)
    end

    test "PlanningFlowCommand accumulates in state.commands" do
      state = started_state()

      next =
        fold(state, "PlanningFlowCommand", %{flow_id: state.flow_id, command: "create_prd"})

      assert length(next.commands) == 1
      assert hd(next.commands).command == "create_prd"
    end

    test "PlanningTraceLinked updates traces map keyed by traceability_key" do
      state = started_state()

      next =
        fold(state, "PlanningTraceLinked", %{
          flow_id: state.flow_id,
          traceability_key: "REQ-008",
          phase_id: "p2"
        })

      assert next.traces["REQ-008"].phase_id == "p2"
    end

    test "PlanningFlowCompleted sets completed?: true" do
      state = started_state()

      next =
        fold(state, "PlanningFlowCompleted", %{flow_id: state.flow_id})

      assert next.completed? == true
      assert next.exists? == true
    end

    test "unknown event types leave state unchanged" do
      state = started_state()

      assert fold(state, "PlanningSomethingElse", %{flow_id: "x"}) == state
    end
  end

  # ---------------------------------------------------------------------------
  # unknown commands
  # ---------------------------------------------------------------------------

  describe "handle_command/2 — unknown command types" do
    test "returns :unhandled" do
      assert :unhandled ==
               PlanningFlow.handle_command(start_state(), %{
                 type: "planning.unknown",
                 payload: %{}
               })
    end
  end
end
