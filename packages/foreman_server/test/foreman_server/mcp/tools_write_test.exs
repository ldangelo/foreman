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

  describe "foreman_work_submit" do
    test "dispatches via CommandGateway with correct envelope" do
      params = %{
        work_id: "work-123",
        project_id: "proj-456",
        workflow: "default",
        prompt: "Do the thing"
      }

      :meck.expect(CommandGateway, :dispatch_operator, fn envelope ->
        assert envelope.type == "work.submit"
        assert envelope.aggregate_id == "work:work-123"

        assert envelope.payload == %{
                 work_id: "work-123",
                 project_id: "proj-456",
                 workflow: "default",
                 prompt: "Do the thing",
                 backend: "jido_harness"
               }

        {:ok, %{work_id: "work-123", status: "submitted"}}
      end)

      result = Tools.call_tool("foreman_work_submit", params)

      assert result == {:ok, %{work_id: "work-123", status: "submitted"}}
      assert :meck.called(CommandGateway, :dispatch_operator, :_)
    end

    test "maps error tuples to MCP tool errors" do
      params = %{
        work_id: "work-123",
        project_id: "proj-456",
        workflow: "default",
        prompt: "Do the thing"
      }

      :meck.expect(CommandGateway, :dispatch_operator, fn _envelope ->
        {:error, {:work_not_found, "work-123"}}
      end)

      result = Tools.call_tool("foreman_work_submit", params)

      assert result ==
               {:error, %ToolError{code: "DOMAIN_ERROR", message: "{:work_not_found, \"work-123\"}"}}
    end

    test "maps invalid_envelope errors to MCP tool errors" do
      params = %{
        work_id: "work-123",
        project_id: "proj-456",
        workflow: "default",
        prompt: "Do the thing"
      }

      :meck.expect(CommandGateway, :dispatch_operator, fn _envelope ->
        {:error, {:invalid_envelope, :missing_work_id}}
      end)

      result = Tools.call_tool("foreman_work_submit", params)

      assert result ==
               {:error, %ToolError{code: "DOMAIN_ERROR", message: "{:invalid_envelope, :missing_work_id}"}}
    end
  end

  describe "foreman_work_cancel" do
    test "dispatches via CommandGateway with correct envelope" do
      params = %{work_id: "work-789"}

      :meck.expect(CommandGateway, :dispatch_operator, fn envelope ->
        assert envelope.type == "work.cancel"
        assert envelope.aggregate_id == "work:work-789"
        assert envelope.payload == %{work_id: "work-789"}
        {:ok, %{work_id: "work-789", status: "cancelled"}}
      end)

      result = Tools.call_tool("foreman_work_cancel", params)

      assert result == {:ok, %{work_id: "work-789", status: "cancelled"}}
      assert :meck.called(CommandGateway, :dispatch_operator, :_)
    end

    test "maps error tuples to MCP tool errors" do
      params = %{work_id: "work-789"}

      :meck.expect(CommandGateway, :dispatch_operator, fn _envelope ->
        {:error, {:work_not_cancellable, "work-789"}}
      end)

      result = Tools.call_tool("foreman_work_cancel", params)

      assert result ==
               {:error, %ToolError{code: "DOMAIN_ERROR", message: "{:work_not_cancellable, \"work-789\"}"}}
    end

    test "maps command_not_allowed errors to MCP tool errors" do
      params = %{work_id: "work-789"}

      :meck.expect(CommandGateway, :dispatch_operator, fn _envelope ->
        {:error, {:command_not_allowed, "work.cancel"}}
      end)

      result = Tools.call_tool("foreman_work_cancel", params)

      assert result ==
               {:error,
                %ToolError{code: "DOMAIN_ERROR", message: "{:command_not_allowed, \"work.cancel\"}"}}
    end
  end
end
