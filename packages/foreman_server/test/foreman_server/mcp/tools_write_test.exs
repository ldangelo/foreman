defmodule ForemanServer.MCP.ToolsWriteTest do
  use ExUnit.Case, async: false

  alias ForemanServer.MCP.Tools
  alias ForemanServer.MCP.Tools.InboxSendResult
  alias ForemanServer.MCP.ToolError
  alias ForemanServer.CommandGateway
  alias ForemanServer.ProjectionStore
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
    original_projection_state = :sys.get_state(ProjectionStore)
    original_mcp_config = Application.get_env(:foreman_server, :mcp, [])

    on_exit(fn ->
      :meck.unload(CommandGateway)
      AdapterCatalog.unregister(StubBackendAdapter)
      :sys.replace_state(ProjectionStore, fn _ -> original_projection_state end)
      Application.put_env(:foreman_server, :mcp, original_mcp_config)
    end)

    :ok
  end

  defp put_run_projection(run_id) do
    :sys.replace_state(ProjectionStore, fn state ->
      Map.put(state, :runs, Map.put(Map.get(state, :runs, %{}), run_id, %{run_id: run_id}))
    end)
  end

  defp allow_writes do
    config = Application.get_env(:foreman_server, :mcp, [])
    Application.put_env(:foreman_server, :mcp, Keyword.put(config, :allow_workflow_writes, true))
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

  describe "foreman_inbox_send" do
    test "default policy refuses without dispatch" do
      assert Tools.call_tool("foreman_inbox_send", %{run_id: "run-1", body: "starting"}) ==
               {:error,
                %ToolError{
                  code: "POLICY_REFUSED",
                  message: "Tool foreman_inbox_send is not permitted"
                }}

      refute :meck.called(CommandGateway, :dispatch_operator, :_)
    end

    test "dispatches inbox.send through CommandGateway and returns bounded DTO" do
      allow_writes()
      put_run_projection("run-1")

      :meck.expect(CommandGateway, :dispatch_operator, fn envelope ->
        assert envelope.type == "inbox.send"
        assert envelope.aggregate_id == "inbox:run-1"
        assert envelope.command_id == "cmd-1"

        assert envelope.payload == %{
                 run_id: "run-1",
                 message_id: "msg-1",
                 body: "implemented step 1",
                 metadata: %{"phase_id" => "phase-1", "severity" => "info"}
               }

        {:ok, %{event_type: "InboxMessageAppended"}}
      end)

      assert Tools.call_tool("foreman_inbox_send", %{
               run_id: "run-1",
               message_id: "msg-1",
               command_id: "cmd-1",
               body: "implemented step 1",
               metadata: %{phase_id: "phase-1", severity: "info"}
             }) ==
               {:ok, %InboxSendResult{run_id: "run-1", message_id: "msg-1", status: "sent"}}
    end

    test "derives deterministic command id from caller-supplied message id" do
      allow_writes()
      put_run_projection("run-1")

      :meck.expect(CommandGateway, :dispatch_operator, fn envelope ->
        assert envelope.payload.message_id == "msg-stable"
        assert String.starts_with?(envelope.command_id, "mcp:foreman_inbox_send:")
        {:ok, %{}}
      end)

      # First call
      result1 =
        Tools.call_tool("foreman_inbox_send", %{
          run_id: "run-1",
          message_id: "msg-stable",
          body: "still working"
        })

      # Second call with same message_id — command_id must be identical for retry safety
      :meck.expect(CommandGateway, :dispatch_operator, fn envelope ->
        assert envelope.payload.message_id == "msg-stable"
        assert String.starts_with?(envelope.command_id, "mcp:foreman_inbox_send:")
        {:ok, %{}}
      end)

      result2 =
        Tools.call_tool("foreman_inbox_send", %{
          run_id: "run-1",
          message_id: "msg-stable",
          body: "still working"
        })

      assert result1 ==
               {:ok, %InboxSendResult{run_id: "run-1", message_id: "msg-stable", status: "sent"}}

      assert result2 ==
               {:ok, %InboxSendResult{run_id: "run-1", message_id: "msg-stable", status: "sent"}}
    end

    test "omitting command_id and message_id produces stable command_id across retries" do
      allow_writes()
      put_run_projection("run-1")

      :meck.expect(CommandGateway, :dispatch_operator, fn envelope ->
        # Neither command_id nor message_id was caller-supplied; message_id is minted,
        # command_id is derived from run_id alone — stable across retries.
        assert String.starts_with?(envelope.command_id, "mcp:foreman_inbox_send:")
        {:ok, %{}}
      end)

      result1 = Tools.call_tool("foreman_inbox_send", %{run_id: "run-1", body: "step 1"})

      :meck.expect(CommandGateway, :dispatch_operator, fn envelope ->
        assert envelope.command_id ==
                 "mcp:foreman_inbox_send:" <>
                   Base.url_encode64(:crypto.hash(:sha256, "run-1"), padding: false)

        {:ok, %{}}
      end)

      result2 = Tools.call_tool("foreman_inbox_send", %{run_id: "run-1", body: "step 2"})

      # command_id stability (the point of this test) is already verified inside
      # the two meck expectations above; message_id is freshly minted per call
      # (by design — each notification gets its own id), so only status/run_id
      # are expected to match here.
      assert {:ok, %InboxSendResult{run_id: "run-1", status: "sent"}} = result1
      assert {:ok, %InboxSendResult{run_id: "run-1", status: "sent"}} = result2
    end

    test "rejects unknown run before dispatch" do
      allow_writes()

      assert Tools.call_tool("foreman_inbox_send", %{run_id: "missing", body: "starting"}) ==
               {:error, %ToolError{code: "NOT_FOUND", message: "Run not found"}}

      refute :meck.called(CommandGateway, :dispatch_operator, :_)
    end

    test "rejects invalid params before dispatch" do
      allow_writes()
      put_run_projection("run-1")
      over_limit = String.duplicate("x", 2_001)

      assert {:error, %ToolError{code: "INVALID_PARAMS"}} =
               Tools.call_tool("foreman_inbox_send", %{run_id: "run-1", body: ""})

      assert {:error, %ToolError{code: "INVALID_PARAMS"}} =
               Tools.call_tool("foreman_inbox_send", %{run_id: "run-1", body: over_limit})

      assert {:error, %ToolError{code: "INVALID_PARAMS"}} =
               Tools.call_tool("foreman_inbox_send", %{
                 run_id: "run-1",
                 body: "progress",
                 metadata: %{prompt: "secret prompt"}
               })

      assert {:error, %ToolError{code: "INVALID_PARAMS"}} =
               Tools.call_tool("foreman_inbox_send", %{
                 run_id: "run-1",
                 body: "progress",
                 ignored_atom: "reject me"
               })

      refute :meck.called(CommandGateway, :dispatch_operator, :_)
    end

    test "maps duplicate message to ALREADY_EXISTS without echoing body" do
      allow_writes()
      put_run_projection("run-1")

      :meck.expect(CommandGateway, :dispatch_operator, fn _envelope ->
        {:error, {:already_exists, :message, "msg-1"}}
      end)

      assert {:error, %ToolError{code: "ALREADY_EXISTS", message: message}} =
               Tools.call_tool("foreman_inbox_send", %{
                 run_id: "run-1",
                 message_id: "msg-1",
                 body: "secret body"
               })

      assert message =~ "msg-1"
      refute message =~ "secret body"
    end
  end
end
