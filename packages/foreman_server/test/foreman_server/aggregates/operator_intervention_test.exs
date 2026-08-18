defmodule ForemanServer.Aggregates.OperatorInterventionTest do
  @moduledoc """
  Tests for `ForemanServer.Aggregates.OperatorIntervention`
  extended with per-workflow operator-timeout (JSI-T009).

  JSI-T009's bounded slice: the aggregate captures a
  `deadline_at_ms` on the `operator.needs` command, stores it
  on the `NeedsOperator` event state, and exposes
  `OperatorIntervention.expired_interventions/1` for the
  scheduler to pick up and emit `RunBlocked` for.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.OperatorIntervention

  describe "operator.needs (JSI-T009 — captures deadline_at_ms)" do
    test "stores deadline_at_ms on the State" do
      deadline = System.system_time(:millisecond) + 30_000
      state = OperatorIntervention.initial_state()
      {:ok, event} = OperatorIntervention.handle_command(state, %{
        type: "operator.needs",
        payload: %{"run_id" => "run-1", "deadline_at_ms" => deadline}
      })
      new_state = OperatorIntervention.apply_event(state, event)
      assert new_state.deadline_at_ms == deadline
    end

    test "deadline_at_ms is nil when the command omits the field" do
      state = OperatorIntervention.initial_state()
      {:ok, event} = OperatorIntervention.handle_command(state, %{
        type: "operator.needs",
        payload: %{"run_id" => "run-1"}
      })
      new_state = OperatorIntervention.apply_event(state, event)
      assert is_nil(new_state.deadline_at_ms)
    end
  end

  describe "expired_interventions/1 (JSI-T009 — scheduler helper)" do
    test "returns interventions whose deadline is in the past" do
      state = OperatorIntervention.initial_state()
      deadline_past = System.system_time(:millisecond) - 1
      deadline_future = System.system_time(:millisecond) + 60_000

      state = %{state | active?: true, run_id: "run-a", deadline_at_ms: deadline_past}
      state_b = %{OperatorIntervention.initial_state() | active?: true, run_id: "run-b", deadline_at_ms: deadline_future}
      state_c = %{OperatorIntervention.initial_state() | active?: false}

      expired = OperatorIntervention.expired_interventions([state, state_b, state_c], deadline_past + 1)
      assert [%{run_id: "run-a"}] = expired
    end

    test "returns [] when no deadlines are set" do
      state = %{OperatorIntervention.initial_state() | active?: true}
      assert [] = OperatorIntervention.expired_interventions([state], 0)
    end
  end
end
