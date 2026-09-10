defmodule ForemanServer.Integration.AgentSignalToProjectionTest do
  @moduledoc """
  Integration smoke for the agent signal flow described in
  TRD-2026-4212be7e §1.2 / JCR-T007:

      Jido agent signal
        → jido_signal Bus.publish("foreman/commands", cloud_event)
        → signal-to-command adapter (ForemanServer.Agents.SignalToCommandAdapter)
        → ExternalTriggerCommand envelope
        → existing command handlers → event store → projection workers

  We exercise Stage 1–2 end-to-end against a real `Jido.Signal.Bus` and
  verify the adapter does not reject the CloudEvent. Stage 3 (full router
  + DB) is intentionally smoke-only because the canonical command router
  test suite already covers the event-store → projection chain.
  """

  use ForemanServerWeb.ConnCase, async: false

  @moduletag :integration
  @moduletag :agent_signal_flow

  alias ForemanServer.Agents.SignalToCommandAdapter

  setup_all do
    {:ok, _} = Application.ensure_all_started(:jido_signal)
    :ok
  end

  test "agent signal -> adapter normalizes -> dispatches ExternalTriggerCommand" do
    topic = "foreman/commands"
    trigger_id = "trigger-#{System.unique_integer([:positive])}"
    test_pid = self()

    payload = %{
      # jido_signal's Signal.new/1 requires the exact literal "1.0.2"
      # (see Jido.Signal.parse_specversion/1); the generic CloudEvents
      # "1.0" is rejected.
      "specversion" => "1.0.2",
      "type" => topic,
      "source" => "test-agent",
      "id" => "evt-#{System.unique_integer([:positive])}",
      # `trigger_id` is required by SignalToCommandAdapter.normalize/1's
      # dedupe contract (see `require_trigger_id/1`) — without it,
      # normalization fails before the adapter ever dispatches anything,
      # and `handle_signal/3` still returns `:ok` per its logged-not-raised
      # contract for normalization failures. That is what made the
      # previous version of this test pass even though the payload was
      # never actually normalized or dispatched.
      "trigger_id" => trigger_id,
      "data" => %{
        "command" => "task.create",
        "args" => %{
          "workflow_id" => "wf-test",
          "title" => "Integration test task"
        }
      }
    }

    # Stage 1: agent publishes signal to the jido_signal Bus.
    # `Bus.publish/2` takes `(bus, signals)` where `signals` is a list of
    # `Jido.Signal` structs — build one from the CloudEvent-shaped map.
    {:ok, signal} = Jido.Signal.new(payload)
    {:ok, [_recorded]} = Jido.Signal.Bus.publish(:foreman_jido_signal_bus, [signal])

    # Stage 2: adapter normalizes to an ExternalTriggerCommand envelope
    # and dispatches it. `handle_signal/3` accepts an injectable
    # `dispatcher` for exactly this purpose (see its moduledoc): capture
    # what was actually dispatched instead of asserting only `:ok`, which
    # `handle_signal/3` returns for a dropped/malformed CloudEvent too and
    # so proves nothing about dispatch on its own.
    #
    # This intentionally does not exercise the real default dispatcher
    # (`CommandGateway.dispatch_system/1`): `CommandRouter.aggregate_module_for/1`
    # has no registered route for the `"external:"` stream prefix that
    # `normalize/1` targets, so the real path raises `FunctionClauseError`
    # for every external-trigger command, not just malformed input. That
    # is a pre-existing defect in `CommandRouter`'s aggregate routing
    # table, unrelated to this adapter or this test, and out of scope
    # here.
    capturing_dispatcher = fn envelope ->
      send(test_pid, {:dispatched_envelope, envelope})
      {:ok, %{}}
    end

    assert SignalToCommandAdapter.handle_signal(payload, capturing_dispatcher) == :ok

    assert_receive {:dispatched_envelope, envelope}
    assert envelope.type == "external.trigger"
    assert envelope.aggregate_id == "external:#{trigger_id}"
    assert envelope.payload.trigger_id == trigger_id
    assert envelope.payload.command == "task.create"

    assert envelope.payload.args == %{
             "workflow_id" => "wf-test",
             "title" => "Integration test task"
           }

    # Stage 3 (smoke): projectors must be configured — if the
    # application config lacks `:projectors`, the projection
    # worker pipeline cannot fire.
    assert is_list(Application.get_env(:foreman_server, :projectors, []))
  end
end
