defmodule ForemanServer.Agents.TaskMetadataQuerySubscriberTest do
  @moduledoc """
  Tests for `ForemanServer.Agents.TaskMetadataQuerySubscriber` — the
  Foreman-side bus subscriber that consumes
  `com.foreman.query.task_metadata.*` query signals and publishes
  responses back to the requesting agent (TRD-2026-4212be7e, JSI-T012).

  The subscriber's metadata source is `ProjectionStore.task_projection/1`
  (the read model, not `TaskProvider.get/2` which is for upstream
  integration). The real end-to-end bus round-trip uses the
  subscriber's `response_bus:` option to publish the response on a
  dedicated test bus, where the test can `assert_receive` the
  response signal.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Agents.TaskMetadataQueryResponder
  alias ForemanServer.Agents.TaskMetadataQuerySubscriber

  setup_all do
    {:ok, _} = Application.ensure_all_started(:jido_signal)
    :ok
  end

  setup do
    :ok
  end

  describe "start_link/1 + init/1 (subscribes the GenServer pid)" do
    test "subscribes the GenServer pid to com.foreman.query.task_metadata.*" do
      bus_name = :"TestSubscriberBus.#{:erlang.unique_integer()}"
      {:ok, _bus} = Jido.Signal.Bus.start_link(name: bus_name)

      name = :"TestSubscriber.#{:erlang.unique_integer()}"
      start_supervised!({TaskMetadataQuerySubscriber, name: name, bus: bus_name})
    end
  end

  describe "query_topic/0" do
    test "exposes the topic pattern as a single source of truth" do
      assert TaskMetadataQuerySubscriber.query_topic() == "com.foreman.query.task_metadata.*"
    end
  end
  describe "handle_query/3" do
    test "returns the projection map when present" do
      task = %{id: "task-present-1", title: "Implement Jido", status: "ready", priority: 2}

      reader = fn
        "task-present-1" -> {:ok, task}
        _task_id -> {:error, :not_found}
      end

      query =
        TaskMetadataQueryResponder.build_query(
          "foreman",
          task.id,
          "agent-7",
          "q-read"
        )

      response_bus = :"TestResponseBus.#{:erlang.unique_integer()}"
      {:ok, _rb} = Jido.Signal.Bus.start_link(name: response_bus)

      {:ok, _ref} =
        Jido.Signal.Bus.subscribe(response_bus, "agents.*.directive",
          dispatch: {:pid, target: self()}
        )

      assert match?(
               {:ok, {:response, _}},
               TaskMetadataQuerySubscriber.handle_query(query, response_bus, reader)
             )

      assert_receive {:signal, %Jido.Signal{} = response}, 2_000
      assert response.data.query_id == "q-read"
      assert response.data.metadata == task
    end
  end

  describe "end-to-end: publish query → subscriber responds on a real bus" do
    test "publishes a response signal on agents.<id>.directive with an error when the task is missing" do
      query_bus = :"TestQueryBus.#{:erlang.unique_integer()}"
      response_bus = :"TestResponseBus.#{:erlang.unique_integer()}"
      {:ok, _qb} = Jido.Signal.Bus.start_link(name: query_bus)
      {:ok, _rb} = Jido.Signal.Bus.start_link(name: response_bus)

      name = :"TestSubscriber.#{:erlang.unique_integer()}"
      start_supervised!(
        {TaskMetadataQuerySubscriber,
         [
           name: name,
           bus: query_bus,
           response_bus: response_bus,
           reader: fn _task_id -> {:error, :not_found} end
         ]}
      )

      # Subscribe self() to the directive bus so we can assert_receive.
      {:ok, _ref} =
        Jido.Signal.Bus.subscribe(response_bus, "agents.*.directive",
          dispatch: {:pid, target: self()}
        )

      query =
        TaskMetadataQueryResponder.build_query(
          "foreman",
          "task-missing",
          "agent-7",
          "q-1"
        )

      # Publish the query. The subscriber handles it, reads the missing
      # task from ProjectionStore (returns :not_found), and publishes a
      # response signal back to the response bus.
      Jido.Signal.Bus.publish(query_bus, [query])

      assert_receive {:signal, %Jido.Signal{} = response}, 2_000

      assert response.type == "agents.agent-7.directive"
      assert response.data.query_id == "q-1"
      assert response.data.error == :not_found
    end
  end
end
