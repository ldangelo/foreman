defmodule ForemanServer.Agents.SignalToCommandWiringTest do
  @moduledoc """
  Verifies the production wiring of JCR-T005: when
  `config :foreman_server, :agent_runtime, signal_bridge_enabled: true`,
  `ForemanServer.Application.maybe_signal_to_command_child/0` returns a
  child spec list that brings up:
    1. a Jido.Signal.Bus named `:foreman_jido_signal_bus`
    2. a `ForemanServer.Agents.SignalToCommandAdapter` named
       `:foreman_signal_to_command_adapter` with `bus: :foreman_jido_signal_bus`,
       which auto-subscribes to the `com.foreman.command.*` topic pattern
       during init/1.

  When `signal_bridge_enabled` is false (default), the helper returns
  `[]` so the bus and adapter are not started.

  The end-to-end test confirms the bus+adapter pair, when actually
  started by the supervision tree, route a published Jido.Signal all
  the way through to a stub dispatcher.
  """

  use ExUnit.Case, async: false

  # Alias the Foreman Application module under a different name so we
  # can call its `maybe_signal_to_command_child/0` helper without
  # shadowing Elixir's built-in `Application` module (which is used
  # below for `Application.put_env/3` to set runtime config).
  alias ForemanServer.Application, as: ForemanApp

  setup_all do
    # The wiring test needs Jido.Signal.Registry (owned by the
    # :jido_signal application) and the Jido.Signal application to
    # be running before any bus is started. Tests start them
    # explicitly so we don't depend on Foreman's full Application
    # boot, which would also try to start Postgres, EventStore, etc.
    {:ok, _} = Application.ensure_all_started(:jido_signal)
    :ok
  end

  setup do
    original = :application.get_env(:foreman_server, :agent_runtime, [])

    on_exit(fn ->
      :application.set_env(:foreman_server, :agent_runtime, original)
    end)

    :ok
  end

  test "returns [] when :agent_runtime is not enabled" do
    Application.put_env(:foreman_server, :agent_runtime, enabled: false)
    assert ForemanApp.maybe_signal_to_command_child() == []
  end

  test "returns [] when :signal_bridge_enabled is false (the default)" do
    Application.put_env(:foreman_server, :agent_runtime, enabled: true)
    assert ForemanApp.maybe_signal_to_command_child() == []
  end

  test "returns the bus + adapter child specs when signal_bridge_enabled: true" do
    Application.put_env(
      :foreman_server,
      :agent_runtime,
      enabled: true,
      signal_bridge_enabled: true
    )

    children = ForemanApp.maybe_signal_to_command_child()

    assert length(children) == 2

    [{bus_module, bus_opts}, {adapter_module, adapter_opts}] = children

    assert bus_module == Jido.Signal.Bus
    assert bus_opts[:name] == :foreman_jido_signal_bus

    assert adapter_module == ForemanServer.Agents.SignalToCommandAdapter

    assert adapter_opts[:name] == :foreman_signal_to_command_adapter
    assert adapter_opts[:bus] == :foreman_jido_signal_bus
  end

  test "end-to-end: starting the children brings up a live bus + adapter, " <>
         "and the adapter receives signals published on the topic" do
    Application.put_env(
      :foreman_server,
      :agent_runtime,
      enabled: true,
      signal_bridge_enabled: true
    )

    # Use unique names so we don't clash with the global ones the
    # application would start in a real boot.
    bus_name = :"TestWiringBus.#{:erlang.unique_integer()}"
    adapter_name = :"TestWiringAdapter.#{:erlang.unique_integer()}"

    # Stub dispatcher records every envelope the adapter invokes.
    stub = start_supervised!({Agent, fn -> [] end}, id: :wiring_stub_dispatcher)

    dispatcher = fn envelope ->
      Agent.update(stub, fn acc -> [envelope | acc] end)
      {:ok, :recorded}
    end

    {:ok, _bus_pid} =
      start_supervised(
        {Jido.Signal.Bus, [name: bus_name]},
        id: :wiring_bus
      )

    start_supervised(
      {ForemanServer.Agents.SignalToCommandAdapter,
       [name: adapter_name, bus: bus_name, dispatcher: dispatcher]},
      id: :wiring_adapter
    )

    # Give the auto-subscribe (sent via send/2 in init/1) time to land.
    Process.sleep(100)

    signal =
      Jido.Signal.new!(%{
        id: "evt-wiring-1",
        source: "jido.test",
        type: "com.foreman.command.wiring",
        specversion: "1.0.2",
        data: %{trigger_id: "trigger-wiring-1", command: "noop", args: %{}}
      })

    Jido.Signal.Bus.publish(bus_name, [signal])

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
    assert envelope.payload.trigger_id == "trigger-wiring-1"
    assert envelope.payload.cloud_event_id == "evt-wiring-1"
  end
end
