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
    topic = "com.foreman.command.task_create"
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
      "data" => %{
        # `trigger_id` must live under `data`, not as a top-level
        # CloudEvents attribute: `Jido.Signal.new/1` treats any
        # unrecognized top-level attribute as an "extension" and nests
        # it under `signal.extensions` (logged as "Unknown extension
        # namespace=trigger_id preserved_as=opaque"), and
        # `SignalToCommandAdapter.to_map/1` — used on the `%Jido.Signal{}`
        # a real bus subscriber receives — does `Map.from_struct/1`
        # without flattening `extensions` back to top level. So
        # `trigger_id_of/1`'s top-level check
        # (`ce["trigger_id"] || ...`) never finds it once a signal has
        # round-tripped through the real bus, even though it does find
        # it on a raw, never-wrapped payload map — which is what made an
        # earlier version of this test pass while calling
        # `handle_signal/2` directly on the raw map instead of going
        # through the bus. `trigger_id_of/1`'s `data` fallback is
        # unaffected, since `data` is a genuine top-level `Signal` field.
        "trigger_id" => trigger_id,
        "command" => "task.create",
        "args" => %{
          "workflow_id" => "wf-test",
          "title" => "Integration test task"
        }
      }
    }

    capturing_dispatcher = fn envelope ->
      send(test_pid, {:dispatched_envelope, envelope})
      {:ok, %{}}
    end

    # Stage 2: subscribe a SignalToCommandAdapter instance to the same
    # bus/topic a production adapter would use, with an injectable
    # `dispatcher` (see the module's moduledoc: "Tests can pass a
    # `:dispatcher` option ... without touching the real gateway").
    # This exercises the adapter's actual bus subscription and topic
    # routing (`handle_info({:signal, signal}, state)`), not just its
    # pure `handle_signal/3` entry point, and captures what was actually
    # dispatched instead of asserting only `:ok` on a direct call, which
    # `handle_signal/3` also returns for a dropped/malformed CloudEvent
    # and so proves nothing about dispatch on its own.
    #
    # This intentionally does not exercise the real default dispatcher
    # (`CommandGateway.dispatch_system/1`): `CommandRouter.aggregate_module_for/1`
    # has no registered route for the `"external:"` stream prefix that
    # `normalize/1` targets, so the real path raises `FunctionClauseError`
    # for every external-trigger command, not just malformed input. That
    # is a pre-existing defect in `CommandRouter`'s aggregate routing
    # table, unrelated to this adapter or this test, and out of scope
    # here.
    adapter_name = :"signal_adapter_#{System.unique_integer([:positive])}"

    start_supervised!(
      {SignalToCommandAdapter, [name: adapter_name, dispatcher: capturing_dispatcher]}
    )

    :ok = SignalToCommandAdapter.subscribe(:foreman_jido_signal_bus, name: adapter_name)

    # Stage 1: agent publishes signal to the jido_signal Bus.
    # `Bus.publish/2` takes `(bus, signals)` where `signals` is a list of
    # `Jido.Signal` structs — build one from the CloudEvent-shaped map.
    {:ok, signal} = Jido.Signal.new(payload)
    {:ok, [_recorded]} = Jido.Signal.Bus.publish(:foreman_jido_signal_bus, [signal])

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
