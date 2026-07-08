import { afterEach, describe, expect, it, vi } from "vitest";
import { ForemanMcpServer, compactMcpPayload } from "../foreman-mcp-server.js";

const originalFetch = globalThis.fetch;
const fetchMock = vi.fn();

function mockJsonResponse(body: unknown): void {
  fetchMock.mockResolvedValueOnce({
    ok: true,
    status: 200,
    json: async () => body,
  } as Response);
}

afterEach(() => {
  fetchMock.mockReset();
  globalThis.fetch = originalFetch;
});

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

  it("normalizes project list output to match the CLI list shape", async () => {
    globalThis.fetch = fetchMock;
    mockJsonResponse({
      ok: true,
      projects: [
        {
          project_id: "project-1",
          config: { name: "Foreman" },
          path: "/repo/foreman",
          default_branch: "dev",
          health: { ok: true },
        },
        {
          id: "archived-1",
          name: "Archived",
          path: "/repo/archived",
          status: "archived",
        },
      ],
    });
    const server = new ForemanMcpServer({ autoStart: false, serverUrl: "http://server.test" });

    const response = await server.handle({
      jsonrpc: "2.0",
      id: 3,
      method: "tools/call",
      params: { name: "foreman.projects.list", arguments: { search: "fore" } },
    });

    expect(response?.result).toMatchObject({
      structuredContent: [
        {
          id: "project-1",
          name: "Foreman",
          path: "/repo/foreman",
          status: "active",
        },
      ],
    });
  });

  it("compacts large MCP payloads before returning them", () => {
    const compacted = compactMcpPayload({
      output: "x".repeat(20),
      items: Array.from({ length: 5 }, (_, index) => ({ index })),
      nested: { a: { b: { c: "hidden" } } },
    }, { maxStringChars: 8, maxArrayItems: 2, maxDepth: 3 });

    expect(compacted).toMatchObject({
      output: "xxxxxxxx… [truncated 12 chars]",
      items: [{ index: 0 }, { index: 1 }, { _mcp_truncated: "3 additional item(s) omitted" }],
      nested: { a: { b: { _mcp_truncated: "nested object omitted (1 key(s))" } } },
    });
  });
});
