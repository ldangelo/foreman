defmodule ForemanServer.BoardItemStateMachineTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.BoardItemStateMachine

  defp created_state(id \\ "bi-1", status \\ "backlog") do
    %BoardItemStateMachine.State{
      exists?: true,
      board_item_id: id,
      status: status,
      terminal?: status == "done",
      created_at_ms: 100,
      last_transition_at_ms: nil,
      history: [{:created, status, 100}]
    }
  end

  describe "initial_state/0" do
    test "returns a non-existent state" do
      state = BoardItemStateMachine.initial_state()
      assert state.exists? == false
      assert state.terminal? == false
      assert state.status == nil
    end
  end

  describe "handle_command/2 — board_item.create" do
    test "emits BoardItemCreated with backlog default status" do
      state = BoardItemStateMachine.initial_state()

      assert {:ok, event_spec} =
               BoardItemStateMachine.handle_command(state, %{
                 type: "board_item.create",
                 payload: %{board_item_id: "bi-1"}
               })

      assert event_spec.stream_id == "board_item:bi-1"
      assert event_spec.event_type == "BoardItemCreated"
      assert event_spec.payload.status == "backlog"
    end

    test "emits BoardItemCreated with explicit status" do
      state = BoardItemStateMachine.initial_state()

      assert {:ok, event_spec} =
               BoardItemStateMachine.handle_command(state, %{
                 type: "board_item.create",
                 payload: %{board_item_id: "bi-2", status: "in_progress"}
               })

      assert event_spec.payload.status == "in_progress"
    end

    test "rejects missing board_item_id" do
      assert {:error, {:missing_or_invalid, :board_item_id}} =
               BoardItemStateMachine.handle_command(
                 BoardItemStateMachine.initial_state(),
                 %{type: "board_item.create", payload: %{}}
               )
    end

    test "rejects invalid status" do
      assert {:error, {:invalid_status, "bogus"}} =
               BoardItemStateMachine.handle_command(
                 BoardItemStateMachine.initial_state(),
                 %{
                   type: "board_item.create",
                   payload: %{board_item_id: "bi-3", status: "bogus"}
                 }
               )
    end

    test "rejects when board_item already exists" do
      state = created_state("bi-1")

      assert {:error, {:already_exists, "bi-1"}} =
               BoardItemStateMachine.handle_command(state, %{
                 type: "board_item.create",
                 payload: %{board_item_id: "bi-1"}
               })
    end
  end

  describe "handle_command/2 — board_item.transition valid paths" do
    test "backlog -> in_progress" do
      state = created_state("bi-1", "backlog")

      assert {:ok, event_spec} =
               BoardItemStateMachine.handle_command(state, %{
                 type: "board_item.transition",
                 payload: %{board_item_id: "bi-1", to_status: "in_progress"}
               })

      assert event_spec.event_type == "BoardItemTransitioned"
      assert event_spec.payload.from_status == "backlog"
      assert event_spec.payload.to_status == "in_progress"
    end

    test "in_progress -> in_review" do
      state = created_state("bi-1", "in_progress")

      assert {:ok, event_spec} =
               BoardItemStateMachine.handle_command(state, %{
                 type: "board_item.transition",
                 payload: %{board_item_id: "bi-1", to_status: "in_review"}
               })

      assert event_spec.payload.to_status == "in_review"
    end

    test "in_review -> done" do
      state = created_state("bi-1", "in_review")

      assert {:ok, event_spec} =
               BoardItemStateMachine.handle_command(state, %{
                 type: "board_item.transition",
                 payload: %{board_item_id: "bi-1", to_status: "done"}
               })

      assert event_spec.payload.to_status == "done"
    end

    test "backlog -> blocked -> backlog round trip" do
      s1 = created_state("bi-1", "backlog")

      assert {:ok, evt_a} =
               BoardItemStateMachine.handle_command(s1, %{
                 type: "board_item.transition",
                 payload: %{board_item_id: "bi-1", to_status: "blocked"}
               })

      s2 =
        BoardItemStateMachine.apply_event(s1, evt_a)

      assert {:ok, evt_b} =
               BoardItemStateMachine.handle_command(s2, %{
                 type: "board_item.transition",
                 payload: %{board_item_id: "bi-1", to_status: "backlog"}
               })

      assert evt_b.payload.from_status == "blocked"
      assert evt_b.payload.to_status == "backlog"
    end
  end

  describe "handle_command/2 — board_item.transition invalid paths" do
    test "backlog -> done is rejected" do
      state = created_state("bi-1", "backlog")

      assert {:error, :invalid_transition} =
               BoardItemStateMachine.handle_command(state, %{
                 type: "board_item.transition",
                 payload: %{board_item_id: "bi-1", to_status: "done"}
               })
    end

    test "in_progress -> blocked is allowed" do
      state = created_state("bi-1", "in_progress")

      assert {:ok, _} =
               BoardItemStateMachine.handle_command(state, %{
                 type: "board_item.transition",
                 payload: %{board_item_id: "bi-1", to_status: "blocked"}
               })
    end

    test "done is terminal — no further transitions" do
      state = created_state("bi-1", "done")

      assert {:error, :already_terminal} =
               BoardItemStateMachine.handle_command(state, %{
                 type: "board_item.transition",
                 payload: %{board_item_id: "bi-1", to_status: "in_progress"}
               })
    end

    test "rejects missing board_item_id" do
      assert {:error, {:missing_or_invalid, :board_item_id}} =
               BoardItemStateMachine.handle_command(
                 BoardItemStateMachine.initial_state(),
                 %{type: "board_item.transition", payload: %{to_status: "in_progress"}}
               )
    end

    test "rejects when board_item does not exist" do
      assert {:error, :not_found} =
               BoardItemStateMachine.handle_command(
                 BoardItemStateMachine.initial_state(),
                 %{
                   type: "board_item.transition",
                   payload: %{board_item_id: "bi-missing", to_status: "in_progress"}
                 }
               )
    end
  end

  describe "handle_command/2 — unknown" do
    test "returns :unhandled" do
      assert :unhandled =
               BoardItemStateMachine.handle_command(BoardItemStateMachine.initial_state(), %{
                 type: "x",
                 payload: %{}
               })
    end
  end

  describe "apply_event/2" do
    test "BoardItemCreated sets exists? + status" do
      state =
        BoardItemStateMachine.apply_event(
          BoardItemStateMachine.initial_state(),
          %{
            event_type: "BoardItemCreated",
            payload: %{board_item_id: "bi-evt", status: "in_review", created_at_ms: 50}
          }
        )

      assert state.exists? == true
      assert state.status == "in_review"
      assert state.created_at_ms == 50
      assert state.terminal? == false
    end

    test "BoardItemTransitioned updates status + last_transition_at_ms" do
      state =
        BoardItemStateMachine.apply_event(created_state("bi-evt", "in_progress"), %{
          event_type: "BoardItemTransitioned",
          payload: %{
            board_item_id: "bi-evt",
            from_status: "in_progress",
            to_status: "in_review",
            transitioned_at_ms: 999
          }
        })

      assert state.status == "in_review"
      assert state.last_transition_at_ms == 999
      assert state.terminal? == false
    end

    test "transition to done flips terminal? to true" do
      state =
        BoardItemStateMachine.apply_event(created_state("bi-evt", "in_review"), %{
          event_type: "BoardItemTransitioned",
          payload: %{
            board_item_id: "bi-evt",
            from_status: "in_review",
            to_status: "done",
            transitioned_at_ms: 1000
          }
        })

      assert state.status == "done"
      assert state.terminal? == true
    end

    test "ignores unknown events" do
      state =
        BoardItemStateMachine.apply_event(BoardItemStateMachine.initial_state(), %{
          event_type: "Unknown",
          payload: %{}
        })

      assert state.exists? == false
    end
  end

  describe "valid_transitions/1 and valid_status?/1" do
    test "valid_transitions/1 returns the successors for a status" do
      assert "in_progress" in BoardItemStateMachine.valid_transitions("backlog")
      assert "done" in BoardItemStateMachine.valid_transitions("in_review")
      assert BoardItemStateMachine.valid_transitions("done") == []
    end

    test "valid_status?/1" do
      assert BoardItemStateMachine.valid_status?("backlog")
      refute BoardItemStateMachine.valid_status?("weird")
    end
  end
end
