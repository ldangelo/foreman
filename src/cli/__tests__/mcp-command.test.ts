import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { mockStartStdio, mockStartHttp, mockServerCtor } = vi.hoisted(() => ({
  mockStartStdio: vi.fn(),
  mockStartHttp: vi.fn(),
  mockServerCtor: vi.fn(),
}));

vi.mock("../../mcp/foreman-mcp-server.js", () => ({
  ForemanMcpServer: vi.fn().mockImplementation(function MockForemanMcpServer(opts: unknown) {
    mockServerCtor(opts);
    return {
      startStdio: mockStartStdio,
      startHttp: mockStartHttp,
    };
  }),
}));

async function freshMcpCommand() {
  vi.resetModules();
  const { mcpCommand } = await import("../commands/mcp.js");
  return mcpCommand;
}

describe("foreman mcp command", () => {
  let exitSpy: ReturnType<typeof vi.spyOn>;
  let errSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    vi.clearAllMocks();
    mockStartStdio.mockReset();
    mockStartHttp.mockReset();
    mockServerCtor.mockReset();
    mockStartHttp.mockResolvedValue(undefined);
    exitSpy = vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      throw new Error(`process.exit(${code ?? ""})`);
    }) as never);
    errSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);
  });

  afterEach(() => {
    exitSpy.mockRestore();
    errSpy.mockRestore();
  });

  it("starts stdio transport by default", async () => {
    const mcpCommand = await freshMcpCommand();

    await mcpCommand.parseAsync([], { from: "user" });

    expect(mockServerCtor).toHaveBeenCalledWith({
      transport: "stdio",
      host: "127.0.0.1",
      port: 4777,
      serverUrl: undefined,
      mcpAuthToken: undefined,
      autoStart: true,
    });
    expect(mockStartStdio).toHaveBeenCalledOnce();
    expect(mockStartHttp).not.toHaveBeenCalled();
  });

  it("starts the HTTP transport and logs the listening URL", async () => {
    const mcpCommand = await freshMcpCommand();

    await mcpCommand.parseAsync([
      "--transport", "http",
      "--host", "0.0.0.0",
      "--port", "4888",
      "--server-url", "http://server:4766",
      "--mcp-auth-token", "secret",
      "--no-auto-start",
    ], { from: "user" });

    expect(mockServerCtor).toHaveBeenCalledWith({
      transport: "http",
      host: "0.0.0.0",
      port: 4888,
      serverUrl: "http://server:4766",
      mcpAuthToken: "secret",
      autoStart: false,
    });
    expect(mockStartHttp).toHaveBeenCalledWith("0.0.0.0", 4888);
    expect(errSpy).toHaveBeenCalledWith("Foreman MCP HTTP server listening on http://0.0.0.0:4888/mcp");
  });

  it("rejects unsupported transports", async () => {
    const mcpCommand = await freshMcpCommand();

    await expect(mcpCommand.parseAsync([
      "--transport", "ws",
    ], { from: "user" })).rejects.toThrow("process.exit(1)");

    expect(mockStartStdio).not.toHaveBeenCalled();
    expect(mockStartHttp).not.toHaveBeenCalled();
    expect(errSpy).toHaveBeenCalledWith("Unsupported MCP transport 'ws'. Use stdio or http.");
  });

  it("rejects invalid HTTP ports", async () => {
    const mcpCommand = await freshMcpCommand();

    await expect(mcpCommand.parseAsync([
      "--transport", "http",
      "--port", "0",
    ], { from: "user" })).rejects.toThrow("process.exit(1)");

    expect(mockStartHttp).not.toHaveBeenCalled();
    expect(errSpy).toHaveBeenCalledWith("Invalid MCP HTTP port '0'.");
  });
});
