defmodule ForemanServer.Agents.OperatorQuestionSubscriberTest do
  @moduledoc """
  Tests for `ForemanServer.Agents.OperatorQuestionSubscriber` — the
  Foreman-side bus subscriber that consumes
  `com.foreman.operator.*` signals (TRD-2026-4212be7e, JSI-T006).

  The TRD pairs JSI-T006 (this subscriber) with JSI-T007 (the
  inbox-API dispatch adapter) and JSI-T008 (the full operator
  question → inbox → directive flow). This module is the bus-side
  wire: the JSI-T007 module consumes the signals and writes
  to the existing `ForemanServer.Inbox` pipeline; this module
  is the bus consumer that hands each signal to that pipeline.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Agents.OperatorQuestionSubscriber

  setup_all do
    {:ok, _} = Application.ensure_all_started(:jido_signal)
    :ok
  end

  describe "start_link/1 + init/1" do
    test "subscribes the GenServer pid (not the caller) to com.foreman.operator.*" do
      bus_name = :"TestOperatorBus.#{:erlang.unique_integer()}"
      {:ok, _bus} = Jido.Signal.Bus.start_link(name: bus_name)

      name = :"TestOperatorSubscriber.#{:erlang.unique_integer()}"
      start_supervised!({OperatorQuestionSubscriber, name: name, bus: bus_name})
    end
  end

  describe "operator_topic/0" do
    test "exposes the operator topic pattern as a single source of truth" do
      assert OperatorQuestionSubscriber.operator_topic() == "com.foreman.operator.*"
    end
  end
end
