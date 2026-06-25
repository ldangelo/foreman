import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { listProjects, sendCommand, ensureRunning } = vi.hoisted(() => ({
  listProjects: vi.fn(),
  sendCommand: vi.fn(),
  ensureRunning: vi.fn(),
}));

vi.mock("../../lib/backend-mode.js", () => ({
  foremanBackendMode: () => "elixir",
}));

vi.mock("../../lib/elixir-server-manager.js", () => ({
  ElixirServerManager: vi.fn(function MockElixirServerManager() {
    return { ensureRunning };
  }),
}));

vi.mock("../../lib/elixir-server-client.js", () => ({
  ElixirServerClient: vi.fn(function MockElixirServerClient() {
    return { listProjects, sendCommand };
  }),
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: vi.fn(() => {
    throw new Error("legacy tRPC should not be used in Elixir mode");
  }),
}));

describe("foreman project Elixir backend parity", () => {
  let originalLog: typeof console.log;
  let originalError: typeof console.error;
  let originalExit: typeof process.exit;

  beforeEach(() => {
    vi.resetModules();
    listProjects.mockReset();
    sendCommand.mockReset();
    ensureRunning.mockReset().mockResolvedValue({ running: true, url: "http://127.0.0.1:4766" });
    originalLog = console.log;
    originalError = console.error;
    originalExit = process.exit;
    console.log = vi.fn();
    console.error = vi.fn();
    process.exit = vi.fn((code?: number) => {
      throw new Error(`process.exit called with code: ${code}`);
    }) as typeof process.exit;
  });

  afterEach(() => {
    console.log = originalLog;
    console.error = originalError;
    process.exit = originalExit;
    vi.restoreAllMocks();
  });

  it("lists projects from Elixir projections", async () => {
    listProjects.mockResolvedValue([
      { project_id: "alpha", name: "Alpha", path: "/repo/alpha", status: "active" },
      { project_id: "beta", path: "/repo/beta", status: "archived" },
    ]);

    const { projectCommand } = await import("../commands/project.js");
    await projectCommand.parseAsync(["list", "--status", "active"], { from: "user" });

    expect(listProjects).toHaveBeenCalledOnce();
    const output = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(output).toContain("Projects (1)");
    expect(output).toContain("Alpha");
    expect(output).not.toContain("beta");
  });

  it("updates and archives projects through Elixir commands", async () => {
    sendCommand.mockResolvedValue({ ok: true, events: ["event-1"], projection_version: 1, correlation_id: "corr" });

    const { projectCommand } = await import("../commands/project.js");
    await projectCommand.parseAsync(["edit", "alpha", "--name", "Renamed", "--default-branch", "dev"], { from: "user" });
    await projectCommand.parseAsync(["remove", "alpha"], { from: "user" });

    expect(sendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_type: "project.update",
      payload: expect.objectContaining({ project_id: "alpha", name: "Renamed", default_branch: "dev" }),
    }));
    expect(sendCommand).toHaveBeenCalledWith(expect.objectContaining({
      command_type: "project.archive",
      payload: { project_id: "alpha" },
    }));
  });
});
