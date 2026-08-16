defmodule ForemanServer.MCP.ToolsWriteTest do
  use ExUnit.Case, async: false

  alias ForemanServer.MCP.Tools
  alias ForemanServer.CommandGateway

  setup do
    {:ok, _} = Application.ensure_all_started(:meck)
    :meck.new(CommandGateway, [:passthrough, :no_link])

    on_exit(fn ->
      :meck.unload(CommandGateway)
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
                 prompt: "Do the thing"
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
               {:error, %{code: "DOMAIN_ERROR", message: "{:work_not_found, \"work-123\"}"}}
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
               {:error, %{code: "DOMAIN_ERROR", message: "{:invalid_envelope, :missing_work_id}"}}
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
               {:error, %{code: "DOMAIN_ERROR", message: "{:work_not_cancellable, \"work-789\"}"}}
    end

    test "maps command_not_allowed errors to MCP tool errors" do
      params = %{work_id: "work-789"}

      :meck.expect(CommandGateway, :dispatch_operator, fn _envelope ->
        {:error, {:command_not_allowed, "work.cancel"}}
      end)

      result = Tools.call_tool("foreman_work_cancel", params)

      assert result ==
               {:error,
                %{code: "DOMAIN_ERROR", message: "{:command_not_allowed, \"work.cancel\"}"}}
    end
  end
end
