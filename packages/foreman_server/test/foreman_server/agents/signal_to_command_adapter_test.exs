defmodule ForemanServer.Agents.SignalToCommandAdapterTest do
  @moduledoc """
  Tests for `ForemanServer.Agents.SignalToCommandAdapter` — the bridge
  between a Jido.Signal.Bus topic (`foreman/commands`) and the existing
  Foreman command gateway (TRD-2026-4212be7e, JCR-T005).

  Three layers of coverage:
    1. Pure normalization (no GenServer, no Bus).
    2. End-to-end with a real `Jido.Signal.Bus` and a stub dispatcher
       injected via the `:dispatcher` option. The test publishes a
       CloudEvent whose `type` is `foreman/commands` (matching the
       adapter's subscription path), and asserts the adapter GenServer
       receives it, normalizes it, and invokes the stub with the exact
       expected `ExternalTriggerCommand` envelope.
    3. Error paths (malformed CloudEvents) do not crash the adapter.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Agents.SignalToCommandAdapter

  setup_all do
    {:ok, _} = Application.ensure_all_started(:jido_signal)
    :ok
  end

  describe "CloudEvent normalization" do
    test "normalizes a CloudEvent to an ExternalTriggerCommand envelope" do
      cloud_event = %{
        "id" => "evt-abc-123",
        "source" => "jido.agent/agent-7",
        "type" => "com.foreman.command.trigger",
        "specversion" => "1.0.2",
        "datacontenttype" => "application/json",
        "data" => %{
          "trigger_id" => "trigger-xyz-789",
          "command" => "create_task",
          "args" => %{"title" => "Implement Jido signal bus"}
        }
      }

      {:ok, envelope} = SignalToCommandAdapter.normalize(cloud_event)

      assert envelope.type == "external.trigger"
      assert envelope.aggregate_id == "external:trigger-xyz-789"
      assert envelope.payload.trigger_id == "trigger-xyz-789"
      assert envelope.payload.cloud_event_id == "evt-abc-123"
      assert envelope.payload.source == "jido.agent/agent-7"
      assert envelope.payload.command == "create_task"
      assert envelope.payload.args == %{"title" => "Implement Jido signal bus"}
    end

    test "rejects CloudEvents missing required specversion" do
      bad = %{
        "id" => "evt-no-version",
        "source" => "x",
        "type" => "x",
        "data" => %{"trigger_id" => "t1"}
      }

      assert {:error, {:invalid_cloud_event, :missing_specversion}} =
               SignalToCommandAdapter.normalize(bad)
    end

    test "rejects CloudEvents missing trigger_id in data" do
      bad = %{
        "id" => "evt-no-trigger",
        "source" => "x",
        "type" => "x",
        "specversion" => "1.0.2",
        "data" => %{"command" => "noop"}
      }

      assert {:error, {:invalid_cloud_event, :missing_trigger_id}} =
               SignalToCommandAdapter.normalize(bad)
    end

    test "accepts trigger_id from data or top-level (CloudEvents extension)" do
      with_top_level = %{
        "id" => "evt-1",
        "source" => "x",
        "type" => "x",
        "specversion" => "1.0.2",
        "trigger_id" => "trigger-top-level",
        "data" => %{}
      }

      assert {:ok, env1} = SignalToCommandAdapter.normalize(with_top_level)
      assert env1.payload.trigger_id == "trigger-top-level"
    end
  end

  describe "end-to-end Bus.publish → adapter.handle_signal → dispatcher" do
    test "publishes a CloudEvent; adapter invokes dispatcher with the envelope" do
      # Stub dispatcher: an Agent that records every envelope it
      # receives. The adapter is started with this fn as its
      # :dispatcher, so handle_signal/2's dispatcher call lands here.
      stub =
        start_supervised!({Agent, fn -> [] end}, id: :adapter_stub_dispatcher)

      dispatcher = fn envelope ->
        Agent.update(stub, fn acc -> [envelope | acc] end)
        {:ok, :recorded}
      end

      # Start a real bus and a real adapter.
      bus_name = :"TestBus.#{:erlang.unique_integer()}"
      adapter_name = :"SignalToCommandAdapter.#{:erlang.unique_integer()}"
      {:ok, _bus} = Jido.Signal.Bus.start_link(name: bus_name)
      start_supervised!({SignalToCommandAdapter, [name: adapter_name, dispatcher: dispatcher]})

      assert :ok = SignalToCommandAdapter.subscribe(bus_name, name: adapter_name)

      # The bus routes by `signal.type` against the subscription's
      # `path` argument (per Jido.Signal.Bus.subscribe/3). The adapter
      # subscribes to the path `com.foreman.command.*`, so the test
      # signal must have a matching type to be routed to the adapter.
      signal =
        Jido.Signal.new!(%{
          id: "evt-e2e-1",
          source: "jido.agent/test",
          specversion: "1.0.2",
          type: "com.foreman.command.trigger",
          data: %{
            trigger_id: "trigger-e2e-1",
            command: "noop",
            args: %{}
          }
        })

      Jido.Signal.Bus.publish(bus_name, [signal])

      # The bus is async; poll briefly for the stub to receive the call.
      envelope =
        Enum.reduce_while(1..20, nil, fn _i, _acc ->
          case Agent.get(stub, & &1) do
            [] ->
              Process.sleep(50)
              {:cont, nil}

            [e | _] ->
              {:halt, e}
          end
        end)

      assert envelope != nil, "stub dispatcher never received the envelope"
      assert envelope.type == "external.trigger"
      assert envelope.payload.trigger_id == "trigger-e2e-1"
      assert envelope.payload.cloud_event_id == "evt-e2e-1"
      assert envelope.payload.command == "noop"
    end
  end

  describe "error paths" do
    test "handle_signal/2 with a malformed CloudEvent logs and returns :ok" do
      stub = start_supervised!({Agent, fn -> 0 end}, id: :adapter_stub_malformed)

      dispatcher = fn _envelope ->
        Agent.update(stub, &(&1 + 1))
        {:ok, :should_not_be_called}
      end

      bad = %{"id" => "evt-bad", "source" => "x", "type" => "x", "data" => %{}}

      assert :ok = SignalToCommandAdapter.handle_signal(bad, dispatcher)

      assert Agent.get(stub, & &1) == 0
    end
  end
end
