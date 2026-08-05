defmodule ForemanServer.PrAssociationTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.PrAssociation

  describe "initial_state/0" do
    test "returns a fresh state with exists? false and nil fields" do
      state = PrAssociation.initial_state()

      assert state.exists? == false
      assert is_nil(state.run_id)
      assert is_nil(state.pr_url)
      assert is_nil(state.pr_number)
      assert is_nil(state.associated_at)
    end
  end

  describe "handle_command/2 — pr.associate" do
    test "emits PrAssociated event with extracted pr_number" do
      state = PrAssociation.initial_state()

      assert {:ok, event_spec} =
               PrAssociation.handle_command(state, %{
                 type: "pr.associate",
                 payload: %{
                   run_id: "run-1",
                   pr_url: "https://github.com/owner/repo/pull/42"
                 }
               })

      assert event_spec.stream_id == "pr_association:run-1"
      assert event_spec.event_type == "PrAssociated"
      assert event_spec.payload.run_id == "run-1"
      assert event_spec.payload.pr_url == "https://github.com/owner/repo/pull/42"
      assert event_spec.payload.pr_number == 42
      assert is_integer(event_spec.payload.associated_at)
    end

    test "emits PrAssociated event with explicit pr_number when provided" do
      state = PrAssociation.initial_state()

      assert {:ok, event_spec} =
               PrAssociation.handle_command(state, %{
                 type: "pr.associate",
                 payload: %{
                   run_id: "run-2",
                   pr_url: "https://example.com/pr/custom",
                   pr_number: 99
                 }
               })

      assert event_spec.payload.pr_number == 99
    end

    test "returns error when run_id is missing" do
      state = PrAssociation.initial_state()

      assert {:error, {:missing_or_invalid, :run_id}} =
               PrAssociation.handle_command(state, %{
                 type: "pr.associate",
                 payload: %{pr_url: "https://github.com/owner/repo/pull/1"}
               })
    end

    test "returns error when pr_url is missing" do
      state = PrAssociation.initial_state()

      assert {:error, {:missing_or_invalid, :pr_url}} =
               PrAssociation.handle_command(state, %{
                 type: "pr.associate",
                 payload: %{run_id: "run-3"}
               })
    end

    test "returns error when pr_url is empty" do
      state = PrAssociation.initial_state()

      assert {:error, {:missing_or_invalid, :pr_url}} =
               PrAssociation.handle_command(state, %{
                 type: "pr.associate",
                 payload: %{run_id: "run-4", pr_url: ""}
               })
    end

    test "returns error when pr_url is malformed (no scheme)" do
      state = PrAssociation.initial_state()

      assert {:error, {:missing_or_invalid, :pr_url}} =
               PrAssociation.handle_command(state, %{
                 type: "pr.associate",
                 payload: %{run_id: "run-5", pr_url: "github.com/owner/repo/pull/1"}
               })
    end
  end

  describe "handle_command/2 — unknown" do
    test "returns :unhandled for unknown command types" do
      state = PrAssociation.initial_state()

      assert :unhandled =
               PrAssociation.handle_command(state, %{
                 type: "pr.disassociate",
                 payload: %{run_id: "run-6"}
               })
    end
  end

  describe "apply_event/2 — PrAssociated" do
    test "folds a PrAssociated payload into state" do
      state =
        PrAssociation.apply_event(
          PrAssociation.initial_state(),
          %{
            event_type: "PrAssociated",
            payload: %{
              run_id: "run-7",
              pr_url: "https://github.com/owner/repo/pull/7",
              pr_number: 7,
              associated_at: 1_700_000_000_000
            }
          }
        )

      assert state.exists? == true
      assert state.run_id == "run-7"
      assert state.pr_url == "https://github.com/owner/repo/pull/7"
      assert state.pr_number == 7
      assert state.associated_at == 1_700_000_000_000
    end

    test "re-association overwrites prior state" do
      state_after_first =
        PrAssociation.apply_event(
          PrAssociation.initial_state(),
          %{
            event_type: "PrAssociated",
            payload: %{
              run_id: "run-8",
              pr_url: "https://github.com/owner/repo/pull/8",
              pr_number: 8,
              associated_at: 100
            }
          }
        )

      state_after_second =
        PrAssociation.apply_event(state_after_first, %{
          event_type: "PrAssociated",
          payload: %{
            run_id: "run-8",
            pr_url: "https://github.com/owner/repo/pull/9",
            pr_number: 9,
            associated_at: 200
          }
        })

      assert state_after_second.pr_url == "https://github.com/owner/repo/pull/9"
      assert state_after_second.pr_number == 9
      assert state_after_second.associated_at == 200
    end

    test "ignores unknown event types" do
      state =
        PrAssociation.apply_event(PrAssociation.initial_state(), %{
          event_type: "SomethingElse",
          payload: %{}
        })

      assert state.exists? == false
    end
  end

  describe "stream_id/1" do
    test "produces deterministic stream id" do
      assert PrAssociation.stream_id("run-9") == "pr_association:run-9"
    end
  end
end
