import { afterEach, describe, expect, it, vi } from "vitest";

const mockResetAction = vi.hoisted(() => vi.fn());

vi.mock("../../cli/commands/reset.js", () => ({
  resetAction: mockResetAction,
}));

import { ForemanMcpServer, compactMcpPayload } from "../foreman-mcp-server.js";

const originalFetch = globalThis.fetch;
const fetchMock = vi.fn();

type ToolMetadata = {
  name: string;
  description: string;
  inputSchema: {
    required?: string[];
    properties?: Record<string, unknown>;
    additionalProperties?: boolean;
  };
};

function isToolMetadata(value: unknown): value is ToolMetadata {
  if (!value || typeof value !== "object") return false;
  if (!("name" in value) || typeof value.name !== "string") return false;
  if (!("description" in value) || typeof value.description !== "string") return false;
  if (!("inputSchema" in value) || !value.inputSchema || typeof value.inputSchema !== "object") return false;
  return true;
}

function toolsFrom(result: unknown): ToolMetadata[] {
  expect(result).toMatchObject({ tools: expect.any(Array) });
  if (!result || typeof result !== "object" || !("tools" in result) || !Array.isArray(result.tools)) {
    throw new Error("Expected MCP tools/list result to contain a tools array");
  }
  if (!result.tools.every(isToolMetadata)) {
    throw new Error("Expected every MCP tool to include name, description, and inputSchema metadata");
  }
  return result.tools;
}


function mockJsonResponse(body: unknown): void {
  fetchMock.mockResolvedValueOnce({
    ok: true,
    status: 200,
    json: async () => body,
  } as Response);
}

afterEach(() => {
  fetchMock.mockReset();
  mockResetAction.mockReset();
  globalThis.fetch = originalFetch;
});

describe("ForemanMcpServer", () => {
  it("exposes MCP tool metadata for current tools including task reset", async () => {
    const server = new ForemanMcpServer({ autoStart: false });
    const response = await server.handle({ jsonrpc: "2.0", id: 1, method: "tools/list" });

    const tools = toolsFrom(response?.result);
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
      "foreman.tasks.reset",
      "foreman.runs.list",
      "foreman.inbox.list",
      "foreman.events.list",
      "foreman.debug.timeline",
    ]));
    expect(tools.find((tool) => tool.name === "foreman.scheduler.status")?.description).toContain("Future use cases");
    const resetTool = tools.find((tool) => tool.name === "foreman.tasks.reset");
    expect(resetTool?.description).toMatch(/\b(PR|pull request)\b/i);
    expect(resetTool?.description).toMatch(/retir|clos|supersed/i);
    expect(resetTool?.description).toMatch(/branch/i);
    expect(resetTool).toMatchObject({
      inputSchema: {
        required: ["task_id"],
        properties: {
          task_id: { type: "string" },
          project_id: { type: "string" },
          project: { type: "string" },
          project_path: { type: "string" },
          reason: { type: "string" },
          dry_run: { type: "boolean" },
          keep_worktree: { type: "boolean" },
        },
        additionalProperties: false,
      },
    });
  });

  it("advertises run inspection with a required run_id", async () => {
    const server = new ForemanMcpServer({ autoStart: false });
    const response = await server.handle({ jsonrpc: "2.0", id: "tools", method: "tools/list" });

    const inspectTool = toolsFrom(response?.result).find((tool) => tool.name === "foreman.runs.inspect");
    expect(inspectTool).toBeDefined();
    expect(inspectTool?.inputSchema.required).toEqual(["run_id"]);
    expect(inspectTool?.inputSchema.properties).toMatchObject({
      run_id: { type: "string" },
    });
    expect(inspectTool?.inputSchema.additionalProperties).toBe(false);
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

  it("returns run list summaries without heavy run details", async () => {
    globalThis.fetch = fetchMock;
    mockJsonResponse({
      ok: true,
      runs: [
        {
          run_id: "run-heavy",
          updated_at: "2026-07-08T12:00:00.000Z",
          status: "completed",
          tool_events: [
            { tool_name: "bash", output: "x".repeat(256) },
            { tool_name: "edit", output: "patched test file" },
          ],
          task_id: "task-1",
          project_id: "project-1",
        },
      ],
    });
    const server = new ForemanMcpServer({ autoStart: false, serverUrl: "http://server.test" });

    const response = await server.handle({
      jsonrpc: "2.0",
      id: "runs-list",
      method: "tools/call",
      params: { name: "foreman.runs.list", arguments: { project_id: "project-1" } },
    });

    expect(response?.error).toBeUndefined();
    expect(response?.result).toEqual(expect.objectContaining({
      structuredContent: [
        {
          run_id: "run-heavy",
          date: "2026-07-08T12:00:00.000Z",
          status: "completed",
        },
      ],
    }));
  });

  it("inspects one run by run_id and returns its full payload", async () => {
    const matchingRun = {
      run_id: "run-target",
      updated_at: "2026-07-08T13:00:00.000Z",
      status: "failed",
      tool_events: [
        { tool_name: "bash", output: "compiler error", exit_code: 1 },
        { tool_name: "read", path: "src/mcp/foreman-mcp-server.ts" },
      ],
      task_id: "task-target",
      project_id: "project-1",
    };
    const otherRun = {
      run_id: "run-other",
      updated_at: "2026-07-08T14:00:00.000Z",
      status: "completed",
      tool_events: [{ tool_name: "bash", output: "other run output" }],
      task_id: "task-other",
      project_id: "project-1",
    };
    globalThis.fetch = fetchMock;
    mockJsonResponse({ ok: true, runs: [otherRun, matchingRun] });
    const server = new ForemanMcpServer({ autoStart: false, serverUrl: "http://server.test" });

    const response = await server.handle({
      jsonrpc: "2.0",
      id: "runs-inspect",
      method: "tools/call",
      params: { name: "foreman.runs.inspect", arguments: { run_id: "run-target" } },
    });

    expect(response?.error).toBeUndefined();
    expect(response?.result).toEqual(expect.objectContaining({
      structuredContent: matchingRun,
    }));
  });

  it("reports a JSON-RPC error when inspecting an unknown run_id", async () => {
    globalThis.fetch = fetchMock;
    mockJsonResponse({
      ok: true,
      runs: [
        {
          run_id: "run-present",
          updated_at: "2026-07-08T15:00:00.000Z",
          status: "completed",
          tool_events: [{ tool_name: "bash", output: "present run output" }],
        },
      ],
    });
    const server = new ForemanMcpServer({ autoStart: false, serverUrl: "http://server.test" });

    const response = await server.handle({
      jsonrpc: "2.0",
      id: "runs-inspect-missing",
      method: "tools/call",
      params: { name: "foreman.runs.inspect", arguments: { run_id: "run-missing" } },
    });

    expect(response?.result).toBeUndefined();
    expect(response?.error?.message).toContain("run-missing");
  });

  it("calls resetAction with MCP reset arguments and returns the exit code", async () => {
    mockResetAction.mockResolvedValueOnce(0);
    const server = new ForemanMcpServer({ autoStart: false });

    const response = await server.handle({
      jsonrpc: "2.0",
      id: "reset",
      method: "tools/call",
      params: {
        name: "foreman.tasks.reset",
        arguments: {
          task_id: "task-123",
          project: "ops",
          project_id: "fallback-project",
          reason: "retry after stale worker",
          dry_run: true,
          keep_worktree: true,
          project_path: "/repo/ops",
        },
      },
    });

    expect(mockResetAction).toHaveBeenCalledOnce();
    expect(mockResetAction).toHaveBeenCalledWith("task-123", {
      project: "ops",
      projectPath: "/repo/ops",
      reason: "retry after stale worker",
      dryRun: true,
      keepWorktree: true,
    });
    expect(response).toEqual({
      jsonrpc: "2.0",
      id: "reset",
      result: {
        content: [{ type: "text", text: JSON.stringify({ ok: true, exit_code: 0 }, null, 2) }],
        structuredContent: { ok: true, exit_code: 0 },
      },
    });
  });

  it("uses project_id as the reset project selector when project is omitted", async () => {
    mockResetAction.mockResolvedValueOnce(0);
    const server = new ForemanMcpServer({ autoStart: false });

    await server.handle({
      jsonrpc: "2.0",
      id: "reset-project-id",
      method: "tools/call",
      params: {
        name: "foreman.tasks.reset",
        arguments: {
          task_id: "task-456",
          project_id: "project-456",
          reason: "operator retry",
          dry_run: false,
          keep_worktree: false,
        },
      },
    });

    expect(mockResetAction).toHaveBeenCalledOnce();
    expect(mockResetAction).toHaveBeenCalledWith("task-456", {
      project: "project-456",
      projectPath: undefined,
      reason: "operator retry",
      dryRun: false,
      keepWorktree: false,
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
