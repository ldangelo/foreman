defmodule ForemanServer.Agents.TaskMetadataQueryResponderTest do
  @moduledoc """
  Tests for `ForemanServer.Agents.TaskMetadataQueryResponder` — the
  Foreman-side consumer of the task-metadata query signal
  (TRD-2026-4212be7e, JSI-T012).

  The Agent→Foreman query signal pattern is
  `com.foreman.query.task_metadata.*` (a Jido-aligned topic, sibling
  to the `com.foreman.command.*` and `agents.<id>.directive` topics
  defined in `JidoSignalTopics`). The responder subscribes to that
  topic, looks up the task via the configured `TaskProvider`, and
  publishes a response signal back to the agent via
  `SignalDirectivePublisher.publish/3` (the Foreman→Agent directive
  bus).

  The two signal types are:
    1. **Query (Agent→Foreman)**   type: `com.foreman.query.task_metadata.<project>`
                                   data:  `%{"task_id" => ..., "query_id" => ...}`
    2. **Response (Foreman→Agent)** type: `agents.<agent_id>.directive`
                                   data:  `%{"query_id" => ..., "metadata" => ...}` or
                                          `%{"query_id" => ..., "error" => ...}`
  """

  use ExUnit.Case, async: false

  # Jido.Signal.new/3 reads the signal extension registry, which lives
  # in the :jido_signal application. Without it, inflate_extensions
  # exits with `no process`. Start the app in setup_all so every
  # test in this module sees a live registry.
  setup_all do
    {:ok, _} = Application.ensure_all_started(:jido_signal)
    :ok
  end

  alias ForemanServer.Agents.TaskMetadataQueryResponder

  describe "build_query/2" do
    test "builds a query signal with the right topic" do
      sig = TaskMetadataQueryResponder.build_query("foreman", "task-123", "agent-7", "q-1")
      assert sig.type == "com.foreman.query.task_metadata.foreman"
      assert sig.data.task_id == "task-123"
      assert sig.data.agent_id == "agent-7"
      assert sig.data.query_id == "q-1"
    end
  end

  describe "build_response/3" do
    test "builds a successful response with metadata" do
      metadata = %{title: "Implement Jido", priority: 1}
      sig = TaskMetadataQueryResponder.build_response("agent-7", "q-1", {:ok, metadata})
      assert sig.type == "agents.agent-7.directive"
      assert sig.data.query_id == "q-1"
      assert sig.data.metadata == metadata
      refute Map.has_key?(sig.data, :error)
    end

    test "builds an error response with the error payload" do
      sig =
        TaskMetadataQueryResponder.build_response("agent-7", "q-1", {:error, :not_found})

      assert sig.type == "agents.agent-7.directive"
      assert sig.data.query_id == "q-1"
      assert sig.data.error == :not_found
      refute Map.has_key?(sig.data, :metadata)
    end
  end

  describe "lookup/2 (stub TaskProvider integration)" do
    test "returns {:ok, metadata} for a successful provider lookup" do
      # We use a stub provider that returns a known task. The real
      # TaskProvider integration is exercised in JSI-T013; here we
      # only verify the wire-shape contract.
      provider = fn _task_id ->
        {:ok, %{id: "task-123", title: "Implement Jido", priority: 1}}
      end

      assert {:ok, %{id: "task-123", title: "Implement Jido", priority: 1}} =
               TaskMetadataQueryResponder.lookup(provider, "task-123")
    end

    test "returns {:error, reason} when the provider returns an error" do
      provider = fn _task_id -> {:error, :not_found} end
      assert {:error, :not_found} = TaskMetadataQueryResponder.lookup(provider, "task-123")
    end
  end
end
