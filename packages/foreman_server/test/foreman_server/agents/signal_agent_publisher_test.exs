defmodule ForemanServer.Agents.SignalAgentPublisherTest do
  @moduledoc """
  Tests for `ForemanServer.Agents.SignalAgentPublisher` — the Foreman
  wrapper that publishes Agent↔Agent signals on the
  `agents.<phase>.directive` topic (TRD-2026-4212be7e, JSI-T002).

  Per the TRD:
    "Implement Agent→Agent signal pub/sub via Bus.publish to
     agents/<phase> topic."

  The Jido-aligned form (Jido's path grammar rejects `/`) is
  `agents.<phase>.directive`. The publisher builds that signal and
  publishes it via the same `Jido.Signal.Bus.publish/2` path that
  JSI-T011's `SignalDirectivePublisher` uses, but addressing an
  arbitrary phase (not just a specific agent id).
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Agents.SignalAgentPublisher

  setup_all do
    {:ok, _} = Application.ensure_all_started(:jido_signal)
    :ok
  end

  describe "publish/3" do
    test "builds a signal on the agents.<phase>.directive topic" do
      bus_name = :"TestAgentBus.#{:erlang.unique_integer()}"
      {:ok, _bus} = Jido.Signal.Bus.start_link(name: bus_name)

      result = SignalAgentPublisher.publish(bus_name, "phase-2", %{note: "nudge"})

      assert {:ok, [recorded]} = result
      assert recorded.type == "agents.phase-2.directive"
    end

    test "round-trips the payload in signal.data" do
      bus_name = :"TestAgentBus.#{:erlang.unique_integer()}"
      {:ok, _bus} = Jido.Signal.Bus.start_link(name: bus_name)

      payload = %{kind: "nudge", message: "stuck on step 3"}
      assert {:ok, [recorded]} = SignalAgentPublisher.publish(bus_name, "phase-1", payload)

      # Jido's data map round-trip via `inflate_extensions` converts
      # atom keys to string keys, so payload `:kind` and `:message`
      # become string values under atom keys. Assert via atom keys.
      assert recorded.signal.data.kind == "nudge"
      assert recorded.signal.data.message == "stuck on step 3"
    end

    test "rejects non-string phase" do
      bus_name = :"TestAgentBus.#{:erlang.unique_integer()}"
      {:ok, _bus} = Jido.Signal.Bus.start_link(name: bus_name)

      assert_raise FunctionClauseError, fn ->
        SignalAgentPublisher.publish(bus_name, 123, %{note: "x"})
      end
    end
  end
end
