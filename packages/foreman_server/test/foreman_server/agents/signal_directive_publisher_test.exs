defmodule ForemanServer.Agents.SignalDirectivePublisherTest do
  @moduledoc """
  Tests for `ForemanServer.Agents.SignalDirectivePublisher` — the
  Foreman-side publisher that emits directives to a Jido agent via
  the `agents.<agent-id>.directive` topic pattern
  (TRD-2026-4212be7e, JSI-T011).
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Agents.SignalDirectivePublisher
  alias ForemanServer.Agents.JidoSignalTopics

  setup_all do
    {:ok, _} = Application.ensure_all_started(:jido_signal)
    :ok
  end

  describe "publish/2 with explicit bus" do
    test "publishes a Jido.Signal on the agent's directive topic" do
      bus_name = :"TestDirectiveBus.#{:erlang.unique_integer()}"
      {:ok, _bus} = Jido.Signal.Bus.start_link(name: bus_name)

      result =
        SignalDirectivePublisher.publish(
          bus_name,
          "agent-7",
          %{directive: "answer_question", question: "what is the task?"}
        )

      assert {:ok, [_recorded]} = result
    end

    test "uses JidoSignalTopics.agent_directive/1 as the topic" do
      bus_name = :"TestDirectiveBus.#{:erlang.unique_integer()}"
      {:ok, _bus} = Jido.Signal.Bus.start_link(name: bus_name)

      expected_topic = JidoSignalTopics.agent_directive("agent-7")
      assert expected_topic == "agents.agent-7.directive"

      assert {:ok, recorded} =
               SignalDirectivePublisher.publish(bus_name, "agent-7", %{directive: "nudge"})

      assert [rec] = recorded
      assert rec.type == expected_topic
    end

    test "preserves the directive payload in signal.data" do
      bus_name = :"TestDirectiveBus.#{:erlang.unique_integer()}"
      {:ok, _bus} = Jido.Signal.Bus.start_link(name: bus_name)

      payload = %{
        directive: "answer_question",
        question: "what is the task?",
        options: %{"timeout_ms" => 30_000}
      }

      assert {:ok, [recorded]} =
               SignalDirectivePublisher.publish(bus_name, "agent-9", payload)

      # The Jido.Bus.RecordedSignal wraps the original Jido.Signal
      # in a `.signal` field; the directive payload lives at
      # `recorded.signal.data`. Each payload key/value must round-trip
      # — Jido stores the data map with atom keys.
      assert is_map(recorded.signal.data)

      for {k, v} <- payload do
        assert Map.fetch!(recorded.signal.data, k) == v
      end
    end
  end

  describe "publish/2 with default production bus" do
    test ":default sentinel resolves to :foreman_jido_signal_bus" do
      assert :default == SignalDirectivePublisher.default_bus_token()
      assert SignalDirectivePublisher.production_bus_name() == :foreman_jido_signal_bus
    end
  end
end
