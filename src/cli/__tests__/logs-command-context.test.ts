import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, mkdirSync, rmSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const {
  mockResolveProjectPathFromOptions,
  mockListRegisteredProjects,
  mockCreateTrpcClient,
  mockForemanBackendMode,
  mockEnsureRunning,
  mockListRuns,
  mockListTasks,
} = vi.hoisted(() => ({
  mockResolveProjectPathFromOptions: vi.fn(),
  mockListRegisteredProjects: vi.fn(),
  mockCreateTrpcClient: vi.fn(),
  mockForemanBackendMode: vi.fn(),
  mockEnsureRunning: vi.fn(),
  mockListRuns: vi.fn(),
  mockListTasks: vi.fn(),
}));

vi.mock("../commands/project-task-support.js", () => ({
  resolveProjectPathFromOptions: mockResolveProjectPathFromOptions,
  listRegisteredProjects: mockListRegisteredProjects,
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: mockCreateTrpcClient,
}));

vi.mock("../../lib/backend-mode.js", () => ({
  foremanBackendMode: mockForemanBackendMode,
}));

vi.mock("../../lib/elixir-server-manager.js", () => ({
  ElixirServerManager: vi.fn().mockImplementation(function MockElixirServerManager() {
    return { ensureRunning: mockEnsureRunning };
  }),
}));

vi.mock("../../lib/elixir-server-client.js", () => ({
  ElixirServerClient: vi.fn().mockImplementation(function MockElixirServerClient() {
    return {
      listRuns: mockListRuns,
      listTasks: mockListTasks,
    };
  }),
}));

import { logsCommand } from "../commands/logs.js";

describe("foreman logs command context", () => {
  const tempDirs: string[] = [];
  let originalHome: string | undefined;

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-logs-command-context-"));
    tempDirs.push(dir);
    return dir;
  }

  beforeEach(() => {
    vi.clearAllMocks();
    originalHome = process.env.HOME;
    const home = makeTempDir();
    const projectDir = join(home, "project");
    mkdirSync(join(projectDir, ".foreman"), { recursive: true });
    mkdirSync(join(home, ".foreman", "logs"), { recursive: true });
    writeFileSync(join(home, ".foreman", "logs", "12345678-1234-1234-1234-123456789abc.log"), JSON.stringify({ type: "tool_execution_start", toolName: "bash", args: { command: "npm test" } }) + "\n");
    process.env.HOME = home;
    mockForemanBackendMode.mockReturnValue("elixir");
    mockResolveProjectPathFromOptions.mockResolvedValue(projectDir);
    mockListRegisteredProjects.mockResolvedValue([{ id: "proj-1", name: "foreman", path: projectDir }]);
    mockEnsureRunning.mockResolvedValue({ running: true, url: "http://127.0.0.1:4766", pid: 1 });
    mockListRuns.mockResolvedValue([{ run_id: "12345678-1234-1234-1234-123456789abc", project_id: "proj-1", task_id: "task-1", status: "completed", created_at: "2026-06-01T00:00:00.000Z" }]);
    mockListTasks.mockResolvedValue([{ task_id: "task-1", project_id: "proj-1", run_id: "12345678-1234-1234-1234-123456789abc", title: "Task 1", status: "completed" }]);
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    vi.spyOn(process, "exit").mockImplementation(((code?: number) => { throw new Error(`process.exit(${code ?? ""})`); }) as never);
  });

  afterEach(() => {
    if (originalHome === undefined) delete process.env.HOME;
    else process.env.HOME = originalHome;
    for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true });
    tempDirs.length = 0;
    vi.restoreAllMocks();
  });

  it("resolves logs through Elixir run/task reads without creating a tRPC client", async () => {
    await logsCommand.parseAsync(["task-1"], { from: "user" });

    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(mockListRuns).toHaveBeenCalledWith({ projectId: "proj-1" });
    expect(mockListTasks).toHaveBeenCalledOnce();
  });

  it("renders the non-raw summary path for Elixir-backed runs", async () => {
    await logsCommand.parseAsync(["task-1"], { from: "user" });

    const rendered = vi.mocked(console.log).mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Logs: task-1");
    expect(rendered).toContain("Run ID:");
    expect(rendered).toContain("Raw log:");
    expect(rendered).toContain("Recent tool activity:");
    expect(rendered).toContain("Use --raw --tail 80");
  });

  it("prints raw log lines in --raw mode", async () => {
    await logsCommand.parseAsync(["task-1", "--raw", "--tail", "2"], { from: "user" });

    const rendered = vi.mocked(console.log).mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("tool_execution_start");
    expect(rendered).toContain("npm test");
  });

  it("resolves a run directly via --run without needing task lookup", async () => {
    await logsCommand.parseAsync(["--run", "12345678-1234-1234-1234-123456789abc"], { from: "user" });

    expect(mockCreateTrpcClient).not.toHaveBeenCalled();
    expect(mockListRuns).toHaveBeenCalledWith({ projectId: "proj-1" });
  });

  it("errors when the raw log file is missing in --raw mode", async () => {
    unlinkSync(join(process.env.HOME!, ".foreman", "logs", "12345678-1234-1234-1234-123456789abc.log"));

    await expect(logsCommand.parseAsync(["task-1", "--raw"], { from: "user" })).rejects.toThrow("process.exit(1)");

    const rendered = vi.mocked(console.error).mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Raw log not found");
  });

  it("errors when no matching run can be resolved", async () => {
    mockListRuns.mockResolvedValue([]);
    mockListTasks.mockResolvedValue([]);

    await expect(logsCommand.parseAsync(["missing-task"], { from: "user" })).rejects.toThrow("process.exit(1)");

    const rendered = vi.mocked(console.error).mock.calls.map((args: unknown[]) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("No run found for 'missing-task'");
  });
});
