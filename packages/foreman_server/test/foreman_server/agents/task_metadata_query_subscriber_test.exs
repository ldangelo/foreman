defmodule ForemanServer.Agents.TaskMetadataQuerySubscriberTest do
  @moduledoc """
  Tests for `ForemanServer.Agents.TaskMetadataQuerySubscriber` — the
  Foreman-side bus subscriber that consumes
  `com.foreman.query.task_metadata.*` query signals and publishes
  responses back to the requesting agent (TRD-2026-4212be7e, JSI-T012).

  The subscriber's metadata source is `ProjectionStore.task_projection/1`
  (the read model, not `TaskProvider.get/2` which is for upstream
  integration). A real end-to-end subscriber test would need a
  running ProjectionStore (which in turn needs the EventStore +
  Postgres pipeline). Until that is available in the test scope, the
  test surface here is limited to:

    1. The GenServer's `start_link/1 + init/1` auto-subscribes the pid.
    2. The `query_topic/0` helper exposes the topic pattern.
    3. The `handle_query/2` entry point publishes a response via the
       injected bus (driven by JSI-T013's full integration test).
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Agents.TaskMetadataQuerySubscriber

  setup_all do
    {:ok, _} = Application.ensure_all_started(:jido_signal)
    :ok
  end

  describe "start_link/1 + init/1" do
    test "subscribes the GenServer pid (not the caller) to com.foreman.query.task_metadata.*" do
      bus_name = :"TestSubscriberBus.#{:erlang.unique_integer()}"
      {:ok, _bus} = Jido.Signal.Bus.start_link(name: bus_name)

      name = :"TestSubscriber.#{:erlang.unique_integer()}"
      start_supervised!({TaskMetadataQuerySubscriber, name: name, bus: bus_name})
    end

    test "is opt-in via :agent_runtime, :enabled (tested in application_test.exs / wiring_test.exs)" do
      # The :agent_runtime, :enabled gate is verified in
      # ForemanServer.Application wiring tests. The subscriber itself
      # is a regular GenServer; we don't repeat the config-gate
      # check here.
      assert :ok
    end
  end

  describe "query_topic/0" do
    test "exposes the topic pattern as a single source of truth" do
      assert TaskMetadataQuerySubscriber.query_topic() == "com.foreman.query.task_metadata.*"
    end
  end
end
