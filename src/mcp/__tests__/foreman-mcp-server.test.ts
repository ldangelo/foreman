import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { ForemanMcpServer } from "../foreman-mcp-server.js";
import { ElixirServerClient } from "../../lib/elixir-server-client.js";

describe("ForemanMcpServer", () => {
  it("exposes MCP tool metadata for current and future Foreman use cases", async () => {
    const server = new ForemanMcpServer({ autoStart: false });
    const response = await server.handle({ jsonrpc: "2.0", id: 1, method: "tools/list" });

    expect(response?.result).toMatchObject({ tools: expect.any(Array) });
    const tools = (response?.result as { tools: Array<{ name: string; description: string }> }).tools;
    expect(tools.map((tool) => tool.name)).toEqual(expect.arrayContaining([
      "foreman.smoke.status",
      "foreman.health",
      "foreman.scheduler.status",
      "foreman.scheduler.tick",
      "foreman.projects.list",
      "foreman.tasks.list",
      "foreman.tasks.get",
      "foreman.tasks.update",
      "foreman.tasks.approve",
      "foreman.tasks.create",
      "foreman.runs.list",
      "foreman.runs.logs",
      "foreman.inbox.list",
      "foreman.events.list",
      "foreman.debug.timeline",
    ]));
    expect(tools.find((tool) => tool.name === "foreman.scheduler.status")?.description).toContain("Future use cases");
  });

  it("returns MCP initialize capabilities", async () => {
    const server = new ForemanMcpServer({ autoStart: false });
    const response = await server.handle({ jsonrpc: "2.0", id: "init", method: "initialize" });

    expect(response).toMatchObject({
      jsonrpc: "2.0",
      id: "init",
      result: {
        capabilities: { tools: {} },
        serverInfo: { name: "foreman-mcp" },
      },
    });
  });

  it("reports unknown tools as JSON-RPC errors", async () => {
    const server = new ForemanMcpServer({ autoStart: false });
    const response = await server.handle({
      jsonrpc: "2.0",
      id: 2,
      method: "tools/call",
      params: { name: "foreman.nope", arguments: {} },
    });

    expect(response?.error?.message).toContain("Unknown Foreman MCP tool");
  });

  describe("foreman.tasks.create", () => {
    it("accepts valid input schema with required title field", async () => {
      const server = new ForemanMcpServer({ autoStart: false });
      const response = await server.handle({ jsonrpc: "2.0", id: 1, method: "tools/list" });

      const tools = (response?.result as { tools: Array<{ name: string; inputSchema: Record<string, unknown> }> }).tools;
      const createTool = tools.find((tool) => tool.name === "foreman.tasks.create");

      expect(createTool).toBeDefined();
      expect(createTool?.inputSchema).toEqual(expect.objectContaining({
        type: "object",
        required: ["title"],
        properties: expect.objectContaining({
          project_id: expect.objectContaining({ type: "string" }),
          project: expect.objectContaining({ type: "string" }),
          title: expect.objectContaining({ type: "string" }),
          description: expect.objectContaining({ type: "string" }),
          task_type: expect.objectContaining({ enum: ["task", "bug", "feature", "epic", "chore", "docs", "question"] }),
          priority: expect.objectContaining({ enum: [1, 2, 3, 4] }),
        }),
      }));
    });

    it("returns error when title is missing", async () => {
      const server = new ForemanMcpServer({ autoStart: false });
      const response = await server.handle({
        jsonrpc: "2.0",
        id: 3,
        method: "tools/call",
        params: { name: "foreman.tasks.create", arguments: { project_id: "test-project" } },
      });

      expect(response?.error?.message).toContain("Missing required field: title");
    });

    it("returns error when project is not found", async () => {
      const server = new ForemanMcpServer({ autoStart: false });
      const response = await server.handle({
        jsonrpc: "2.0",
        id: 4,
        method: "tools/call",
        params: { name: "foreman.tasks.create", arguments: { title: "Test task" } },
      });

      expect(response?.error?.message).toContain("Project not found");
    });

    it("returns error for invalid priority value", async () => {
      const server = new ForemanMcpServer({ autoStart: false });
      const response = await server.handle({
        jsonrpc: "2.0",
        id: 5,
        method: "tools/call",
        params: { name: "foreman.tasks.create", arguments: { project_id: "test-project", title: "Test", priority: 5 } },
      });

      expect(response?.error?.message).toContain("Invalid priority");
    });

    it("returns error for invalid task_type value", async () => {
      const server = new ForemanMcpServer({ autoStart: false });
      const response = await server.handle({
        jsonrpc: "2.0",
        id: 6,
        method: "tools/call",
        params: { name: "foreman.tasks.create", arguments: { project_id: "test-project", title: "Test", task_type: "invalid" } },
      });

      expect(response?.error?.message).toContain("Invalid task_type");
    });

    it("includes task_id in payload when sending command to Elixir", async () => {
      const mockSendCommand = vi.spyOn(ElixirServerClient.prototype, "sendCommand").mockResolvedValue({
        ok: true,
        events: ["TaskCreated"],
        projection_version: 1,
        correlation_id: "test-123",
      });

      const server = new ForemanMcpServer({ autoStart: false });
      const response = await server.handle({
        jsonrpc: "2.0",
        id: 7,
        method: "tools/call",
        params: { name: "foreman.tasks.create", arguments: { project_id: "test-project", title: "Test task", priority: 2 } },
      });

      expect(response?.result).toBeDefined();
      expect(mockSendCommand).toHaveBeenCalledWith(
        expect.objectContaining({
          command_type: "task.create",
          payload: expect.objectContaining({
            task_id: expect.stringMatching(/^test-project-.{5}$/),
            project_id: "test-project",
            title: "Test task",
            priority: 2,
          }),
        }),
      );
      mockSendCommand.mockRestore();
    });
  });
});
