import { describe, expect, it } from "vitest";
import { ForemanMcpServer } from "../foreman-mcp-server.js";

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
      "foreman.runs.list",
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
});
