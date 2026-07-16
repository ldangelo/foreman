import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { EventEmitter } from "node:events";

const {
  mockResolveProjectPathFromOptions,
  mockForemanBackendMode,
  mockListRegisteredProjects,
  mockForProject,
  mockSpawn,
  mockEnsureRunning,
} = vi.hoisted(() => ({
  mockResolveProjectPathFromOptions: vi.fn(),
  mockForemanBackendMode: vi.fn(),
  mockListRegisteredProjects: vi.fn(),
  mockForProject: vi.fn(),
  mockSpawn: vi.fn(),
  mockEnsureRunning: vi.fn(),
}));

vi.mock("../commands/project-task-support.js", () => ({
  resolveProjectPathFromOptions: (...args: unknown[]) => mockResolveProjectPathFromOptions(...args),
  listRegisteredProjects: (...args: unknown[]) => mockListRegisteredProjects(...args),
}));

vi.mock("../../lib/backend-mode.js", () => ({
  foremanBackendMode: (...args: unknown[]) => mockForemanBackendMode(...args),
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: {
    forProject: (...args: unknown[]) => mockForProject(...args),
  },
}));

vi.mock("node:child_process", () => ({
  spawn: (...args: unknown[]) => mockSpawn(...args),
}));

vi.mock("../../lib/elixir-server-manager.js", () => ({
  ElixirServerManager: vi.fn().mockImplementation(function MockElixirServerManager() {
    return { ensureRunning: mockEnsureRunning };
  }),
}));

async function freshLogsCommand() {
  vi.resetModules();
  const { logsCommand } = await import("../commands/logs.js");
  return logsCommand;
}

describe("logs command local fallback", () => {
  let exitSpy: ReturnType<typeof vi.spyOn>;
  let originalHome: string | undefined;

  beforeEach(() => {
    vi.clearAllMocks();
    originalHome = process.env.HOME;
    process.env.HOME = process.cwd();
    process.exitCode = undefined;
    mockResolveProjectPathFromOptions.mockResolvedValue("/tmp/project");
    mockForemanBackendMode.mockReturnValue("node");
    mockListRegisteredProjects.mockResolvedValue([]);
    mockEnsureRunning.mockRejectedValue(new Error("server unavailable"));
    vi.spyOn(console, "log").mockImplementation(() => undefined);
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    exitSpy = vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      throw new Error(`process.exit(${code ?? ""})`);
    }) as never);
  });

  afterEach(() => {
    if (originalHome === undefined) delete process.env.HOME;
    else process.env.HOME = originalHome;
    vi.restoreAllMocks();
  });

  it("falls back to the local store when backend resolution is unavailable", async () => {
    mockForProject.mockImplementation((projectPath: string) => {
      if (projectPath === "/tmp/project") {
        return {
          getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1", path: "/tmp/project" }),
          getRun: vi.fn().mockReturnValue(null),
          getRunsForTask: vi.fn().mockReturnValue([
            {
              id: "run-1",
              task_id: "task-1",
              status: "completed",
              started_at: "2026-01-01T00:00:00.000Z",
              completed_at: "2026-01-01T00:01:00.000Z",
              created_at: "2026-01-01T00:00:00.000Z",
            },
          ]),
          getRunProgress: vi.fn().mockReturnValue({ currentPhase: "qa", turns: 2, toolCalls: 1, costUsd: 0.01 }),
          close: vi.fn(),
        };
      }
      return {
        close: vi.fn(),
      };
    });

    const logsCommand = await freshLogsCommand();
    // When raw log is missing but not in --raw mode, command succeeds with fallback
    await expect(logsCommand.parseAsync(["task-1"], { from: "user" })).resolves.toBeDefined();

    expect(mockForProject).toHaveBeenCalledWith("/tmp/project");
  });

  it("prints only non-empty raw log lines in --raw mode", async () => {
    const runId = "run-raw-1";
    const fs = await import("node:fs");
    const path = await import("node:path");
    const home = process.env.HOME!;
    fs.mkdirSync(path.join(home, ".foreman", "logs"), { recursive: true });
    fs.writeFileSync(path.join(home, ".foreman", "logs", `${runId}.log`), "\n{\"a\":1}\n\n{\"b\":2}\n", "utf8");

    mockForProject.mockImplementation(() => ({
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1", path: "/tmp/project" }),
      getRun: vi.fn().mockReturnValue({
        id: runId,
        task_id: "task-1",
        status: "completed",
        started_at: null,
        completed_at: null,
        created_at: "2026-01-01T00:00:00.000Z",
      }),
      getRunsForTask: vi.fn().mockReturnValue([]),
      getRunProgress: vi.fn().mockReturnValue(null),
      close: vi.fn(),
    }));

    const logsCommand = await freshLogsCommand();
    await logsCommand.parseAsync(["--run", runId, "--raw", "--tail", "10"], { from: "user" });

    expect(vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? ""))).toEqual(['{"a":1}', '{"b":2}']);
  });

  it("sets process.exitCode from tail -f in follow mode", async () => {
    const runId = "run-follow-1";
    const fs = await import("node:fs");
    const path = await import("node:path");
    const home = process.env.HOME!;
    fs.mkdirSync(path.join(home, ".foreman", "logs"), { recursive: true });
    fs.writeFileSync(path.join(home, ".foreman", "logs", `${runId}.log`), '{"a":1}\n', "utf8");

    mockForProject.mockImplementation(() => ({
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1", path: "/tmp/project" }),
      getRun: vi.fn().mockReturnValue({
        id: runId,
        task_id: "task-1",
        status: "completed",
        started_at: null,
        completed_at: null,
        created_at: "2026-01-01T00:00:00.000Z",
      }),
      getRunsForTask: vi.fn().mockReturnValue([]),
      getRunProgress: vi.fn().mockReturnValue(null),
      close: vi.fn(),
    }));

    mockSpawn.mockImplementation(() => {
      const child = new EventEmitter() as EventEmitter & { on: typeof EventEmitter.prototype.on };
      queueMicrotask(() => child.emit("exit", 7));
      return child;
    });

    const logsCommand = await freshLogsCommand();
    await logsCommand.parseAsync(["--run", runId, "--follow"], { from: "user" });

    expect(mockSpawn).toHaveBeenCalledWith("tail", ["-f", expect.stringContaining(`${runId}.log`)], { stdio: "inherit" });
    expect(process.exitCode).toBe(7);
  });
});
