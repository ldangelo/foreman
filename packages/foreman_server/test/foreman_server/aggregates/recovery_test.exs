defmodule ForemanServer.Aggregates.RecoveryTest do
  @moduledoc """
  TRD-011: Recovery aggregate unit tests.

  Pins the observation-before-action contract:

    * `recovery.observe_external_worker` and `recovery.require` are the
      observation commands; they emit `ExternalWorkerObserved` /
      `WorkerRecoveryRequired` and don't require a prior observation.
    * `recovery.reattach`, `recovery.restart`, `recovery.needs_operator`,
      `recovery.resolve` are action commands; each requires at least
      one observation. Without one they return
      `{:error, :recovery_requires_observation}`.
    * Once `RecoveryResolved` has been observed, all subsequent commands
      return `{:error, :recovery_resolved}`.
    * `apply_event/2` folds observations and actions into separate
      lists; `attempts` advances only on action events.
    * Stream id is deterministic: `"recovery:<run_id>"`.
  """

  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.Recovery

  defp uuid, do: EventStore.UUID.uuid4()

  # ---------------------------------------------------------------------------
  # handle_command/2 — observation commands
  # ---------------------------------------------------------------------------

  describe "handle_command/2 — observation commands (no prior observation required)" do
    test "recovery.observe_external_worker emits ExternalWorkerObserved from initial_state" do
      run_id = uuid()
      cmd = %{type: "recovery.observe_external_worker", payload: %{run_id: run_id, source: "ci"}}

      assert {:ok, spec} = Recovery.handle_command(Recovery.initial_state(), cmd)
      assert spec.event_type == "ExternalWorkerObserved"
      assert spec.stream_id == "recovery:#{run_id}"
      assert spec.payload.run_id == run_id
      assert spec.payload.source == "ci"
    end

    test "recovery.require emits WorkerRecoveryRequired from initial_state" do
      run_id = uuid()
      cmd = %{type: "recovery.require", payload: %{run_id: run_id, reason: "heartbeat_timeout"}}

      assert {:ok, spec} = Recovery.handle_command(Recovery.initial_state(), cmd)
      assert spec.event_type == "WorkerRecoveryRequired"
      assert spec.stream_id == "recovery:#{run_id}"
      assert spec.payload.run_id == run_id
      assert spec.payload.reason == "heartbeat_timeout"
    end

    test "observation command rejects non-string run_id" do
      cmd = %{type: "recovery.require", payload: %{reason: "x"}}

      assert {:error, {:missing_or_invalid, :run_id}} =
               Recovery.handle_command(Recovery.initial_state(), cmd)
    end
  end

  # ---------------------------------------------------------------------------
  # handle_command/2 — action commands require prior observation
  # ---------------------------------------------------------------------------

  describe "handle_command/2 — action commands require prior observation" do
    setup do
      run_id = uuid()

      state_after_observation =
        Recovery.apply_event(Recovery.initial_state(), %{
          event_type: "WorkerRecoveryRequired",
          payload: %{run_id: run_id, reason: "heartbeat_timeout", sequence: 0}
        })

      {:ok, run_id: run_id, state: state_after_observation}
    end

    test "recovery.reattach succeeds after observation", ctx do
      cmd = %{type: "recovery.reattach", payload: %{run_id: ctx.run_id, session_id: "s1"}}

      assert {:ok, spec} = Recovery.handle_command(ctx.state, cmd)
      assert spec.event_type == "WorkerReattached"
      assert spec.stream_id == "recovery:#{ctx.run_id}"
      assert spec.payload.session_id == "s1"
    end

    test "recovery.restart succeeds after observation", ctx do
      cmd = %{type: "recovery.restart", payload: %{run_id: ctx.run_id, adapter: "A"}}

      assert {:ok, spec} = Recovery.handle_command(ctx.state, cmd)
      assert spec.event_type == "WorkerRestarted"
      assert spec.payload.adapter == "A"
    end

    test "recovery.needs_operator succeeds after observation", ctx do
      cmd = %{type: "recovery.needs_operator", payload: %{run_id: ctx.run_id, why: "stuck"}}

      assert {:ok, spec} = Recovery.handle_command(ctx.state, cmd)
      assert spec.event_type == "NeedsOperator"
      assert spec.payload.why == "stuck"
    end

    test "recovery.resolve succeeds after observation", ctx do
      cmd = %{type: "recovery.resolve", payload: %{run_id: ctx.run_id, outcome: "reattached"}}

      assert {:ok, spec} = Recovery.handle_command(ctx.state, cmd)
      assert spec.event_type == "RecoveryResolved"
      assert spec.payload.outcome == "reattached"
    end
  end

  describe "handle_command/2 — action commands without observation" do
    test "recovery.reattach returns :recovery_requires_observation from initial_state" do
      run_id = uuid()

      assert {:error, :recovery_requires_observation} =
               Recovery.handle_command(Recovery.initial_state(), %{
                 type: "recovery.reattach",
                 payload: %{run_id: run_id}
               })
    end

    test "recovery.restart returns :recovery_requires_observation from initial_state" do
      run_id = uuid()

      assert {:error, :recovery_requires_observation} =
               Recovery.handle_command(Recovery.initial_state(), %{
                 type: "recovery.restart",
                 payload: %{run_id: run_id}
               })
    end

    test "recovery.needs_operator returns :recovery_requires_observation from initial_state" do
      run_id = uuid()

      assert {:error, :recovery_requires_observation} =
               Recovery.handle_command(Recovery.initial_state(), %{
                 type: "recovery.needs_operator",
                 payload: %{run_id: run_id}
               })
    end

    test "recovery.resolve returns :recovery_requires_observation from initial_state" do
      run_id = uuid()

      assert {:error, :recovery_requires_observation} =
               Recovery.handle_command(Recovery.initial_state(), %{
                 type: "recovery.resolve",
                 payload: %{run_id: run_id}
               })
    end
  end

  # ---------------------------------------------------------------------------
  # handle_command/2 — resolved gate
  # ---------------------------------------------------------------------------

  describe "handle_command/2 — resolved gate" do
    setup do
      run_id = uuid()

      state =
        Recovery.initial_state()
        |> Recovery.apply_event(%{
          event_type: "WorkerRecoveryRequired",
          payload: %{run_id: run_id, reason: "heartbeat_timeout", sequence: 0}
        })
        |> Recovery.apply_event(%{
          event_type: "RecoveryResolved",
          payload: %{run_id: run_id, outcome: "reattached", sequence: 1}
        })

      {:ok, run_id: run_id, state: state}
    end

    test "all subsequent commands are rejected with :recovery_resolved", ctx do
      for type <- [
            "recovery.observe_external_worker",
            "recovery.require",
            "recovery.reattach",
            "recovery.restart",
            "recovery.needs_operator",
            "recovery.resolve"
          ] do
        assert {:error, :recovery_resolved} =
                 Recovery.handle_command(ctx.state, %{type: type, payload: %{run_id: ctx.run_id}})
      end
    end
  end

  describe "handle_command/2 — non-recovery commands" do
    test "returns :unhandled for unknown command types" do
      assert :unhandled =
               Recovery.handle_command(Recovery.initial_state(), %{
                 type: "worker.record",
                 payload: %{}
               })
    end
  end

  # ---------------------------------------------------------------------------
  # apply_event/2 — typed event fold
  # ---------------------------------------------------------------------------

  describe "apply_event/2 — typed event fold" do
    test "observation events populate observations, status 'observed', attempts unchanged" do
      run_id = uuid()

      state =
        Recovery.initial_state()
        |> Recovery.apply_event(%{
          event_type: "WorkerFailureSimulated",
          payload: %{run_id: run_id, scenario: "kill -9", sequence: 0}
        })
        |> Recovery.apply_event(%{
          event_type: "ExternalWorkerObserved",
          payload: %{run_id: run_id, source: "ci", sequence: 1}
        })

      assert state.exists? == true
      assert state.run_id == run_id
      assert length(state.observations) == 2
      assert state.actions == []
      assert state.attempts == 0
      assert state.status == "observed"
    end

    test "action events populate actions, advance attempts, status reflects action type" do
      run_id = uuid()

      state =
        Recovery.initial_state()
        |> Recovery.apply_event(%{
          event_type: "WorkerRecoveryRequired",
          payload: %{run_id: run_id, sequence: 0}
        })
        |> Recovery.apply_event(%{
          event_type: "WorkerReattached",
          payload: %{run_id: run_id, sequence: 1}
        })
        |> Recovery.apply_event(%{
          event_type: "WorkerRestarted",
          payload: %{run_id: run_id, sequence: 2}
        })
        |> Recovery.apply_event(%{
          event_type: "NeedsOperator",
          payload: %{run_id: run_id, why: "stuck", sequence: 3}
        })

      assert length(state.actions) == 3
      assert state.attempts == 3
      assert state.status == "needs_operator"
    end

    test "RecoveryResolved sets status to 'resolved'" do
      run_id = uuid()

      state =
        Recovery.initial_state()
        |> Recovery.apply_event(%{
          event_type: "WorkerRecoveryRequired",
          payload: %{run_id: run_id, sequence: 0}
        })
        |> Recovery.apply_event(%{
          event_type: "RecoveryResolved",
          payload: %{run_id: run_id, outcome: "reattached", sequence: 1}
        })

      assert state.status == "resolved"
    end

    test "unknown event types leave state unchanged" do
      state =
        Recovery.apply_event(Recovery.initial_state(), %{
          event_type: "TotallyUnknown",
          payload: %{run_id: uuid()}
        })

      assert state.exists? == false
      assert state.attempts == 0
      assert state.observations == []
      assert state.actions == []
    end
  end

  # ---------------------------------------------------------------------------
  # Idempotency: deterministic command_id key
  # ---------------------------------------------------------------------------

  describe "idempotency contract" do
    test "two recovery.require commands with the same key produce identical event specs" do
      run_id = uuid()
      cmd = %{type: "recovery.require", payload: %{run_id: run_id, reason: "x"}}

      assert {:ok, a} = Recovery.handle_command(Recovery.initial_state(), cmd)
      assert {:ok, b} = Recovery.handle_command(Recovery.initial_state(), cmd)

      assert a.event_type == b.event_type
      assert a.stream_id == b.stream_id
      assert a.payload.run_id == b.payload.run_id
      assert a.payload.reason == b.payload.reason
    end
  end
end
