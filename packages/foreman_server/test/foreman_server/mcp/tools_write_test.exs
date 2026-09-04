defmodule ForemanServer.MCP.ToolsWriteTest do
  use ExUnit.Case, async: false

  alias ForemanServer.MCP.Tools
  alias ForemanServer.MCP.ToolError
  alias ForemanServer.CommandGateway
  alias ForemanServer.AgentRuntime.{AdapterCatalog, BackendAdapter}

  # `foreman_work_submit` gates on `Router.manual/1` (default backend
  # "jido_harness") before ever touching CommandGateway. Router.manual/1
  # always reads the production global AdapterCatalog (no override hook),
  # and test env boots it empty (`config :foreman_server, :agent_runtime,
  # adapters: []`), so without a registered adapter every call falls
  # through to `{:error, :no_available_backend}` before dispatch. Register
  # a minimal stub adapter for the duration of this test (see
  # skill://foreman-test-isolation root cause #10).
  defmodule StubBackendAdapter do
    @moduledoc false
    @behaviour BackendAdapter
    @impl true
    def name, do: :jido_harness
    @impl true
    def capabilities,
      do: %{type: :cli, strengths: [:general], weaknesses: [], supported_contexts: [:code]}

    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "stub", %{}}
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:meck)
    :meck.new(CommandGateway, [:passthrough, :no_link])
    {:ok, _} = AdapterCatalog.register(StubBackendAdapter)

    on_exit(fn ->
      :meck.unload(CommandGateway)
      AdapterCatalog.unregister(StubBackendAdapter)
    end)

    :ok
  end

  describe "foreman_task_create" do
    test "dispatches via CommandGateway with correct envelope" do
      params = %{
        task_id: "task-123",
        project_id: "proj-456",
        workflow: "default",
        prompt: "Do the thing",
        description: "Task description"
      }

      :meck.expect(CommandGateway, :dispatch_operator, fn envelope ->
        assert envelope.type == "task.create"
        assert envelope.aggregate_id == "task:task-123"

        assert envelope.payload == %{
                 task_id: "task-123",
                 project_id: "proj-456",
                 task_type: "task",
                 workflow_type: "default",
                 prompt: "Do the thing",
                 description: "Task description",
                 title: "task-123",
                 provider_tracked: false,
                 auto_approve: true
               }

        {:ok, %{task_id: "task-123", status: "ready"}}
      end)

      result = Tools.call_tool("foreman_task_create", params)

      assert result == {:ok, %{task_id: "task-123", status: "ready"}}
      assert :meck.called(CommandGateway, :dispatch_operator, :_)
    end

    test "mints a task_id when none is supplied" do
      params = %{
        project_id: "proj-456",
        workflow: "default",
        prompt: "Do the thing",
        description: "Task description"
      }

      :meck.expect(CommandGateway, :dispatch_operator, fn envelope ->
        assert String.starts_with?(envelope.payload.task_id, "adhoc-")
        assert envelope.aggregate_id == "task:#{envelope.payload.task_id}"
        {:ok, %{task_id: envelope.payload.task_id, status: "ready"}}
      end)

      result = Tools.call_tool("foreman_task_create", params)

      assert {:ok, %{task_id: task_id, status: "ready"}} = result
      assert String.starts_with?(task_id, "adhoc-")
    end

    test "passes caller-supplied task_type through to the task.create envelope" do
      params = %{
        task_id: "task-123",
        project_id: "proj-456",
        workflow: "plan",
        task_type: "feature",
        prompt: "Plan the thing",
        description: "Task description"
      }

      :meck.expect(CommandGateway, :dispatch_operator, fn envelope ->
        assert envelope.payload.task_type == "feature"
        assert envelope.payload.workflow_type == "plan"
        {:ok, %{task_id: "task-123", status: "ready"}}
      end)

      assert Tools.call_tool("foreman_task_create", params) ==
               {:ok, %{task_id: "task-123", status: "ready"}}
    end

    test "maps error tuples to MCP tool errors" do
      params = %{
        task_id: "task-123",
        project_id: "proj-456",
        workflow: "default",
        prompt: "Do the thing",
        description: "Task description"
      }

      :meck.expect(CommandGateway, :dispatch_operator, fn _envelope ->
        {:error, {:task_not_found, "task-123"}}
      end)

      result = Tools.call_tool("foreman_task_create", params)

      assert result ==
               {:error,
                %ToolError{code: "DOMAIN_ERROR", message: "{:task_not_found, \"task-123\"}"}}
    end

    test "maps invalid_envelope errors to MCP tool errors" do
      params = %{
        task_id: "task-123",
        project_id: "proj-456",
        workflow: "default",
        prompt: "Do the thing",
        description: "Task description"
      }

      :meck.expect(CommandGateway, :dispatch_operator, fn _envelope ->
        {:error, {:invalid_envelope, :missing_project_id}}
      end)

      result = Tools.call_tool("foreman_task_create", params)

      assert result ==
               {:error,
                %ToolError{
                  code: "DOMAIN_ERROR",
                  message: "{:invalid_envelope, :missing_project_id}"
                }}
    end
  end

  describe "foreman_task_update" do
    test "dispatches only supported mutable fields via task.update" do
      params = %{
        task_id: "task-123",
        title: "New title",
        description: "New description",
        priority: 2,
        status: "blocked",
        ignored_atom: "drop me"
      }

      :meck.expect(CommandGateway, :dispatch_operator, fn envelope ->
        assert envelope.type == "task.update"
        assert envelope.aggregate_id == "task:task-123"

        assert envelope.payload == %{
                 task_id: "task-123",
                 title: "New title",
                 description: "New description",
                 priority: 2,
                 status: "blocked"
               }

        {:ok, %{task_id: "task-123", status: "blocked"}}
      end)

      assert Tools.call_tool("foreman_task_update", params) ==
               {:ok, %{task_id: "task-123", status: "blocked"}}
    end

    test "rejects no-op and unsupported-field payloads without dispatch" do
      assert Tools.call_tool("foreman_task_update", %{
               task_id: "task-123",
               ignored_atom: "drop me"
             }) ==
               {:error, %ToolError{code: "INVALID_PARAMS", message: "No update fields provided"}}

      refute :meck.called(CommandGateway, :dispatch_operator, :_)
    end

    test "maps task.update domain failures to DOMAIN_ERROR" do
      :meck.expect(CommandGateway, :dispatch_operator, fn _envelope ->
        {:error, {:invalid_task_status, "merged"}}
      end)

      assert Tools.call_tool("foreman_task_update", %{task_id: "task-123", status: "merged"}) ==
               {:error,
                %ToolError{code: "DOMAIN_ERROR", message: "{:invalid_task_status, \"merged\"}"}}
    end
  end

  describe "foreman_run_cancel" do
    test "dispatches via CommandGateway with correct envelope" do
      params = %{run_id: "run-789", reason: "operator requested"}

      :meck.expect(CommandGateway, :dispatch_operator, fn envelope ->
        assert envelope.type == "run.cancel"
        assert envelope.aggregate_id == "run:run-789"
        assert envelope.payload == %{run_id: "run-789", reason: "operator requested"}
        {:ok, %{run_id: "run-789", status: "cancelled"}}
      end)

      result = Tools.call_tool("foreman_run_cancel", params)

      assert result == {:ok, %{run_id: "run-789", status: "cancelled"}}
      assert :meck.called(CommandGateway, :dispatch_operator, :_)
    end

    test "maps error tuples to MCP tool errors" do
      params = %{run_id: "run-789"}

      :meck.expect(CommandGateway, :dispatch_operator, fn _envelope ->
        {:error, {:run_not_found, "run-789"}}
      end)

      result = Tools.call_tool("foreman_run_cancel", params)

      assert result ==
               {:error,
                %ToolError{code: "DOMAIN_ERROR", message: "{:run_not_found, \"run-789\"}"}}
    end

    test "maps command_not_allowed errors to MCP tool errors" do
      params = %{run_id: "run-789"}

      :meck.expect(CommandGateway, :dispatch_operator, fn _envelope ->
        {:error, {:command_not_allowed, "run.cancel"}}
      end)

      result = Tools.call_tool("foreman_run_cancel", params)

      assert result ==
               {:error,
                %ToolError{
                  code: "DOMAIN_ERROR",
                  message: "{:command_not_allowed, \"run.cancel\"}"
                }}
    end
  end
end
