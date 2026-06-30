import * as fs from "node:fs";
import path from "node:path";
import { homedir } from "node:os";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const {
  MockForemanStore,
  MockSentinelAgent,
  mockCreateTaskClient,
  mockEnsureCliPostgresPool,
  mockListRegisteredProjects,
  mockPostgresStoreForProject,
  mockResolveRepoRootProjectPath,
  mockVcsCreate,
  mockRunOnce,
  mockStart,
  mockStop,
} = vi.hoisted(() => {
  const mockCreateTaskClient = vi.fn().mockResolvedValue({
    taskClient: {
      create: vi.fn(),
      list: vi.fn(),
      ready: vi.fn(),
      show: vi.fn(),
      update: vi.fn(),
    },
  });

  const mockEnsureCliPostgresPool = vi.fn();
  const mockListRegisteredProjects = vi.fn().mockResolvedValue([]);
  const mockPostgresStoreForProject = vi.fn();
  const mockResolveRepoRootProjectPath = vi.fn().mockResolvedValue("/mock/project");

  const mockRunOnce = vi.fn().mockResolvedValue({
    status: "passed",
    durationMs: 1000,
    commitHash: "abc1234",
    output: "",
  });
  const mockStart = vi.fn();
  const mockStop = vi.fn();

  const MockForemanStore = vi.fn(function (this: Record<string, unknown>) {
    throw new Error("new ForemanStore() should not be used in sentinel commands");
  }) as unknown as ReturnType<typeof vi.fn> & { forProject: ReturnType<typeof vi.fn> };

  const localStore = {
    close: vi.fn(),
    isOpen: vi.fn(() => true),
    getProjectByPath: vi.fn().mockReturnValue({ id: "proj-123", path: "/mock/project", name: "test" }),
    logEvent: vi.fn().mockResolvedValue(undefined),
    recordSentinelRun: vi.fn().mockResolvedValue(undefined),
    updateSentinelRun: vi.fn().mockResolvedValue(undefined),
    upsertSentinelConfig: vi.fn().mockResolvedValue(undefined),
    getSentinelConfig: vi.fn().mockResolvedValue(null),
    getSentinelRuns: vi.fn().mockResolvedValue([]),
  };

  MockForemanStore.forProject = vi.fn(() => localStore);

  const MockSentinelAgent = vi.fn(function (this: Record<string, unknown>) {
    this.runOnce = mockRunOnce;
    this.start = mockStart;
    this.stop = mockStop;
    this.isRunning = vi.fn().mockReturnValue(false);
  });

  const mockVcsCreate = vi.fn().mockResolvedValue({
    getRepoRoot: vi.fn(),
  });

  return {
    mockCreateTaskClient,
    mockEnsureCliPostgresPool,
    mockListRegisteredProjects,
    mockPostgresStoreForProject,
    mockResolveRepoRootProjectPath,
    mockRunOnce,
    mockStart,
    mockStop,
    MockForemanStore,
    MockSentinelAgent,
    mockVcsCreate,
  };
});

vi.mock("../../lib/task-client-factory.js", () => ({
  createTaskClient: (...args: unknown[]) => mockCreateTaskClient(...args),
}));
vi.mock("../../lib/store.js", () => ({ ForemanStore: MockForemanStore }));
vi.mock("../../lib/postgres-store.js", () => ({ PostgresStore: { forProject: mockPostgresStoreForProject } }));
vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: (...args: unknown[]) => mockVcsCreate(...args),
  },
}));
vi.mock("../../orchestrator/sentinel.js", () => ({ SentinelAgent: MockSentinelAgent }));
vi.mock("../commands/project-task-support.js", () => ({
  ensureCliPostgresPool: (...args: unknown[]) => mockEnsureCliPostgresPool(...args),
  listRegisteredProjects: (...args: unknown[]) => mockListRegisteredProjects(...args),
  resolveRepoRootProjectPath: (...args: unknown[]) => mockResolveRepoRootProjectPath(...args),
}));

import { sentinelCommand } from "../commands/sentinel.js";

async function invokeSentinel(subcommand: string): Promise<void> {
  await sentinelCommand.parseAsync([subcommand], { from: "user" });
}

describe("sentinel command store context", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(process, "exit").mockImplementation((() => {}) as () => never);

    // Default: no registered projects
    mockListRegisteredProjects.mockResolvedValue([]);
    mockResolveRepoRootProjectPath.mockResolvedValue("/mock/project");
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("resolves registered sentinel subcommands to the registered project path for run-once", async () => {
    mockListRegisteredProjects.mockResolvedValue([
      { id: "registered-proj", path: "/canonical/project", name: "test" },
    ]);

    const mockStore = {
      close: vi.fn(),
      isOpen: () => true,
      logEvent: vi.fn().mockResolvedValue(undefined),
      recordSentinelRun: vi.fn().mockResolvedValue(undefined),
      updateSentinelRun: vi.fn().mockResolvedValue(undefined),
      upsertSentinelConfig: vi.fn().mockResolvedValue(undefined),
      getSentinelConfig: vi.fn().mockResolvedValue(null),
      getSentinelRuns: vi.fn().mockResolvedValue([]),
    };
    mockPostgresStoreForProject.mockReturnValue(mockStore);

    try {
      await invokeSentinel("run-once");
    } catch {
      // Expected - exit is mocked
    }

    expect(mockListRegisteredProjects).toHaveBeenCalled();
  });

  it("stop uses listRegisteredProjects for project resolution", async () => {
    mockListRegisteredProjects.mockResolvedValue([
      { id: "registered-proj", path: "/canonical/project", name: "test" },
    ]);

    const mockStore = {
      close: vi.fn(),
      isOpen: () => true,
      logEvent: vi.fn().mockResolvedValue(undefined),
      recordSentinelRun: vi.fn().mockResolvedValue(undefined),
      updateSentinelRun: vi.fn().mockResolvedValue(undefined),
      upsertSentinelConfig: vi.fn().mockResolvedValue(undefined),
      getSentinelConfig: vi.fn().mockResolvedValue(null),
      getSentinelRuns: vi.fn().mockResolvedValue([]),
    };
    mockPostgresStoreForProject.mockReturnValue(mockStore);

    try {
      await invokeSentinel("stop");
    } catch {
      // Expected - exit is mocked
    }

    expect(mockListRegisteredProjects).toHaveBeenCalled();
  });

  it("status uses listRegisteredProjects for project resolution", async () => {
    mockListRegisteredProjects.mockResolvedValue([
      { id: "registered-proj", path: "/canonical/project", name: "test" },
    ]);

    const mockStore = {
      close: vi.fn(),
      isOpen: () => true,
      logEvent: vi.fn().mockResolvedValue(undefined),
      recordSentinelRun: vi.fn().mockResolvedValue(undefined),
      updateSentinelRun: vi.fn().mockResolvedValue(undefined),
      upsertSentinelConfig: vi.fn().mockResolvedValue(undefined),
      getSentinelConfig: vi.fn().mockResolvedValue(null),
      getSentinelRuns: vi.fn().mockResolvedValue([]),
    };
    mockPostgresStoreForProject.mockReturnValue(mockStore);

    try {
      await invokeSentinel("status");
    } catch {
      // Expected - exit is mocked
    }

    expect(mockListRegisteredProjects).toHaveBeenCalled();
  });

  it("keeps local unregistered behavior unchanged for run-once", async () => {
    mockListRegisteredProjects.mockResolvedValue([]);
    mockResolveRepoRootProjectPath.mockResolvedValue("/mock/project");

    try {
      await invokeSentinel("run-once");
    } catch {
      // Expected - exit is mocked
    }

    // For unregistered projects, ForemanStore is used but should throw
    expect(mockResolveRepoRootProjectPath).toHaveBeenCalled();
  });

  it("run-once prints dry-run mode and failure output when tests do not pass", async () => {
    mockListRegisteredProjects.mockResolvedValue([
      { id: "registered-proj", path: "/canonical/project", name: "test" },
    ]);

    const mockStore = {
      close: vi.fn(),
      isOpen: () => true,
      logEvent: vi.fn().mockResolvedValue(undefined),
      recordSentinelRun: vi.fn().mockResolvedValue(undefined),
      updateSentinelRun: vi.fn().mockResolvedValue(undefined),
      upsertSentinelConfig: vi.fn().mockResolvedValue(undefined),
      getSentinelConfig: vi.fn().mockResolvedValue(null),
      getSentinelRuns: vi.fn().mockResolvedValue([]),
    };
    mockPostgresStoreForProject.mockReturnValue(mockStore);
    mockRunOnce.mockResolvedValueOnce({
      status: "failed",
      durationMs: 2500,
      commitHash: "deadbeef",
      output: "x".repeat(2105),
    });

    try {
      await sentinelCommand.parseAsync(["run-once", "--project", "registered-proj", "--dry-run"], { from: "user" });
    } catch {
      // exit mocked
    }

    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("(dry-run mode)");
    expect(rendered).toContain("Tests FAILED");
    expect(rendered).toContain("Output (last 2000 chars):");
    expect(rendered).toContain("deadbeef".slice(0, 8));
  });

  it("run-once reports explicit unknown project selections", async () => {
    mockListRegisteredProjects.mockResolvedValue([]);
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);

    try {
      await sentinelCommand.parseAsync(["run-once", "--project", "missing-project"], { from: "user" });
    } catch {
      // exit mocked
    }

    expect(errorSpy).toHaveBeenCalledWith(expect.stringContaining("No project found matching 'missing-project'"));
  });

  it("run-once prints ERROR status and trailing output when the sentinel errors", async () => {
    mockListRegisteredProjects.mockResolvedValue([
      { id: "registered-proj", path: "/canonical/project", name: "test" },
    ]);

    const mockStore = {
      close: vi.fn(),
      isOpen: () => true,
      logEvent: vi.fn().mockResolvedValue(undefined),
      recordSentinelRun: vi.fn().mockResolvedValue(undefined),
      updateSentinelRun: vi.fn().mockResolvedValue(undefined),
      upsertSentinelConfig: vi.fn().mockResolvedValue(undefined),
      getSentinelConfig: vi.fn().mockResolvedValue(null),
      getSentinelRuns: vi.fn().mockResolvedValue([]),
    };
    mockPostgresStoreForProject.mockReturnValue(mockStore);
    mockRunOnce.mockResolvedValueOnce({
      status: "error",
      durationMs: 1500,
      commitHash: null,
      output: "sentinel boom",
    });

    try {
      await sentinelCommand.parseAsync(["run-once", "--project", "registered-proj"], { from: "user" });
    } catch {
      // exit mocked
    }

    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Tests ERROR");
    expect(rendered).toContain("Output (last 2000 chars):");
    expect(rendered).toContain("sentinel boom");
  });

  it("keeps local unregistered behavior unchanged for status", async () => {
    mockListRegisteredProjects.mockResolvedValue([]);
    mockResolveRepoRootProjectPath.mockResolvedValue("/mock/project");

    try {
      await invokeSentinel("status");
    } catch {
      // Expected - exit is mocked
    }

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalled();
  });

  it("keeps local unregistered behavior unchanged for stop", async () => {
    mockListRegisteredProjects.mockResolvedValue([]);
    mockResolveRepoRootProjectPath.mockResolvedValue("/mock/project");

    try {
      await invokeSentinel("stop");
    } catch {
      // Expected - exit is mocked
    }

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalled();
  });

  it("uses resolveProject pattern for all sentinel subcommands", () => {
    const source = fs.readFileSync(path.resolve(__dirname, "../commands/sentinel.ts"), "utf8");

    // New implementation uses resolveProject which calls listRegisteredProjects
    expect(source).toContain("listRegisteredProjects");
    expect(source).not.toContain("resolveSentinelRegisteredProject"); // Old function removed
  });

  it("list command uses listRegisteredProjects", async () => {
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "Project 1", path: "/path/1" },
      { id: "proj-2", name: "Project 2", path: "/path/2" },
    ]);

    const mockStore = {
      close: vi.fn(),
      isOpen: () => true,
      logEvent: vi.fn().mockResolvedValue(undefined),
      recordSentinelRun: vi.fn().mockResolvedValue(undefined),
      updateSentinelRun: vi.fn().mockResolvedValue(undefined),
      upsertSentinelConfig: vi.fn().mockResolvedValue(undefined),
      getSentinelConfig: vi.fn().mockResolvedValue(null),
      getSentinelRuns: vi.fn().mockResolvedValue([]),
    };
    mockPostgresStoreForProject.mockReturnValue(mockStore);

    try {
      await invokeSentinel("list");
    } catch {
      // Expected - exit is mocked
    }

    expect(mockListRegisteredProjects).toHaveBeenCalled();
    expect(mockEnsureCliPostgresPool).toHaveBeenCalled();
  });

  it("start prints native issue-tracker messaging and cleans up on SIGINT", async () => {
    mockListRegisteredProjects.mockResolvedValue([
      { id: "registered-proj", path: "/canonical/project", name: "test" },
    ]);

    const mockStore = {
      close: vi.fn(),
      isOpen: () => true,
      logEvent: vi.fn().mockResolvedValue(undefined),
      recordSentinelRun: vi.fn().mockResolvedValue(undefined),
      updateSentinelRun: vi.fn().mockResolvedValue(undefined),
      upsertSentinelConfig: vi.fn().mockResolvedValue(undefined),
      getSentinelConfig: vi.fn().mockResolvedValue(null),
      getSentinelRuns: vi.fn().mockResolvedValue([]),
    };
    mockPostgresStoreForProject.mockReturnValue(mockStore);
    vi.doMock("../../lib/project-config.js", () => ({
      loadProjectConfig: vi.fn().mockReturnValue({ issueTracker: { backend: "github" } }),
    }));
    vi.spyOn(process, "on").mockImplementation(((event: string, handler: (...args: unknown[]) => void) => {
      if (event === "SIGINT") {
        handler();
      }
      return process;
    }) as never);
    vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      throw new Error(`process.exit(${code ?? ""})`);
    }) as never);

    await expect(sentinelCommand.parseAsync(["start", "--project", "registered-proj", "--dry-run"], { from: "user" })).rejects.toThrow("process.exit(1)");

    expect(mockStart).toHaveBeenCalledTimes(1);
    expect(mockStore.upsertSentinelConfig).toHaveBeenCalledWith("registered-proj", expect.objectContaining({ enabled: 1, pid: process.pid }));
    expect(mockStore.upsertSentinelConfig).toHaveBeenCalledWith("registered-proj", { enabled: 0, pid: null });
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Issue tracker: GitHub");
    expect(rendered).toContain("QA Sentinel started");
    expect(rendered).toContain("Sentinel stopped.");
  });

  it("status --json returns lock and runs for a registered project", async () => {
    mockListRegisteredProjects.mockResolvedValue([
      { id: "registered-proj", path: "/canonical/project", name: "test" },
    ]);

    const mockStore = {
      close: vi.fn(),
      isOpen: () => true,
      logEvent: vi.fn().mockResolvedValue(undefined),
      recordSentinelRun: vi.fn().mockResolvedValue(undefined),
      updateSentinelRun: vi.fn().mockResolvedValue(undefined),
      upsertSentinelConfig: vi.fn().mockResolvedValue(undefined),
      getSentinelConfig: vi.fn().mockResolvedValue({ branch: "main", test_command: "npm test", interval_minutes: 30 }),
      getSentinelRuns: vi.fn().mockResolvedValue([{ id: "run-1", status: "passed", started_at: "2026-01-01T00:00:00.000Z", completed_at: "2026-01-01T00:01:00.000Z", commit_hash: "abc12345" }]),
    };
    mockPostgresStoreForProject.mockReturnValue(mockStore);
    vi.spyOn(process, "kill").mockImplementation(() => true as never);
    const lockDir = path.join(homedir(), ".foreman", "sentinels");
    const lockPath = path.join(lockDir, "registered-proj.lock");
    fs.mkdirSync(lockDir, { recursive: true });
    fs.writeFileSync(lockPath, JSON.stringify({ pid: 1234, startedAt: "2026-01-01T00:00:00.000Z", branch: "main", intervalMinutes: 30, testCommand: "npm test" }));

    try {
      await sentinelCommand.parseAsync(["status", "--project", "registered-proj", "--json"], { from: "user" });
    } catch {
      // exit mocked
    } finally {
      fs.rmSync(lockPath, { force: true });
    }

    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain('"branch": "main"');
    expect(rendered).toContain('"pid": 1234');
    expect(rendered).toContain('"status": "passed"');
  });

  it("list --json reports sentinelRunning for active lockfiles", async () => {
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "Project 1", path: "/path/1" },
    ]);

    const mockStore = {
      close: vi.fn(),
      isOpen: () => true,
      logEvent: vi.fn().mockResolvedValue(undefined),
      recordSentinelRun: vi.fn().mockResolvedValue(undefined),
      updateSentinelRun: vi.fn().mockResolvedValue(undefined),
      upsertSentinelConfig: vi.fn().mockResolvedValue(undefined),
      getSentinelConfig: vi.fn().mockResolvedValue({ enabled: 1 }),
      getSentinelRuns: vi.fn().mockResolvedValue([]),
    };
    mockPostgresStoreForProject.mockReturnValue(mockStore);
    vi.spyOn(process, "kill").mockImplementation(() => true as never);
    const lockDir = path.join(homedir(), ".foreman", "sentinels");
    const lockPath = path.join(lockDir, "proj-1.lock");
    fs.mkdirSync(lockDir, { recursive: true });
    fs.writeFileSync(lockPath, JSON.stringify({ pid: 4567, startedAt: "2026-01-01T00:00:00.000Z", branch: "main", intervalMinutes: 30, testCommand: "npm test" }));

    try {
      await sentinelCommand.parseAsync(["list", "--json"], { from: "user" });
    } catch {
      // exit mocked
    } finally {
      fs.rmSync(lockPath, { force: true });
    }

    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain('"sentinelRunning": true');
    expect(rendered).toContain('"pid": 4567');
  });

  it("list --json still prints the empty-state message when no projects are registered", async () => {
    mockListRegisteredProjects.mockResolvedValue([]);

    try {
      await sentinelCommand.parseAsync(["list", "--json"], { from: "user" });
    } catch {
      // exit mocked
    }

    expect(vi.mocked(console.log)).toHaveBeenCalledWith(expect.stringContaining("No projects registered. Run `foreman init` first."));
  });

  it("status removes stale lockfiles and reports stopped with no runs", async () => {
    mockListRegisteredProjects.mockResolvedValue([
      { id: "registered-proj", path: "/canonical/project", name: "test" },
    ]);

    const mockStore = {
      close: vi.fn(),
      isOpen: () => true,
      logEvent: vi.fn().mockResolvedValue(undefined),
      recordSentinelRun: vi.fn().mockResolvedValue(undefined),
      updateSentinelRun: vi.fn().mockResolvedValue(undefined),
      upsertSentinelConfig: vi.fn().mockResolvedValue(undefined),
      getSentinelConfig: vi.fn().mockResolvedValue({ branch: "main", test_command: "npm test", interval_minutes: 30 }),
      getSentinelRuns: vi.fn().mockResolvedValue([]),
    };
    mockPostgresStoreForProject.mockReturnValue(mockStore);
    vi.spyOn(process, "kill").mockImplementation(() => { throw new Error("dead"); });
    const lockDir = path.join(homedir(), ".foreman", "sentinels");
    const lockPath = path.join(lockDir, "registered-proj.lock");
    fs.mkdirSync(lockDir, { recursive: true });
    fs.writeFileSync(lockPath, JSON.stringify({ pid: 9999, startedAt: "2026-01-01T00:00:00.000Z", branch: "main", intervalMinutes: 30, testCommand: "npm test" }));

    try {
      await sentinelCommand.parseAsync(["status", "--project", "registered-proj"], { from: "user" });
    } catch {
      // exit mocked
    }

    expect(fs.existsSync(lockPath)).toBe(false);
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Sentinel status:");
    expect(rendered).toContain("No sentinel runs recorded yet.");
  });

  it("status --json reports null lock and empty runs when no sentinel is running", async () => {
    mockListRegisteredProjects.mockResolvedValue([
      { id: "registered-proj", path: "/canonical/project", name: "test" },
    ]);

    const mockStore = {
      close: vi.fn(),
      isOpen: () => true,
      logEvent: vi.fn().mockResolvedValue(undefined),
      recordSentinelRun: vi.fn().mockResolvedValue(undefined),
      updateSentinelRun: vi.fn().mockResolvedValue(undefined),
      upsertSentinelConfig: vi.fn().mockResolvedValue(undefined),
      getSentinelConfig: vi.fn().mockResolvedValue({ branch: "main", test_command: "npm test", interval_minutes: 30 }),
      getSentinelRuns: vi.fn().mockResolvedValue([]),
    };
    mockPostgresStoreForProject.mockReturnValue(mockStore);
    const lockPath = path.join(homedir(), ".foreman", "sentinels", "registered-proj.lock");
    fs.rmSync(lockPath, { force: true });

    try {
      await sentinelCommand.parseAsync(["status", "--project", "registered-proj", "--json"], { from: "user" });
    } catch {
      // exit mocked
    }

    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain('"config"');
    expect(rendered).toContain('"lock": null');
    expect(rendered).toContain('"runs": []');
  });

  it("stop --force kills the sentinel, removes lock, and disables config", async () => {
    mockListRegisteredProjects.mockResolvedValue([
      { id: "registered-proj", path: "/canonical/project", name: "test" },
    ]);

    const mockStore = {
      close: vi.fn(),
      isOpen: () => true,
      logEvent: vi.fn().mockResolvedValue(undefined),
      recordSentinelRun: vi.fn().mockResolvedValue(undefined),
      updateSentinelRun: vi.fn().mockResolvedValue(undefined),
      upsertSentinelConfig: vi.fn().mockResolvedValue(undefined),
      getSentinelConfig: vi.fn().mockResolvedValue(null),
      getSentinelRuns: vi.fn().mockResolvedValue([]),
    };
    mockPostgresStoreForProject.mockReturnValue(mockStore);
    vi.spyOn(process, "kill").mockImplementation(() => true as never);
    const lockDir = path.join(homedir(), ".foreman", "sentinels");
    const lockPath = path.join(lockDir, "registered-proj.lock");
    fs.mkdirSync(lockDir, { recursive: true });
    fs.writeFileSync(lockPath, JSON.stringify({ pid: 2222, startedAt: "2026-01-01T00:00:00.000Z", branch: "main", intervalMinutes: 30, testCommand: "npm test" }));

    try {
      await sentinelCommand.parseAsync(["stop", "--project", "registered-proj", "--force"], { from: "user" });
    } catch {
      // exit mocked
    }

    expect(process.kill).toHaveBeenCalledWith(2222, 0);
    expect(process.kill).toHaveBeenCalledWith(2222, "SIGKILL");
    expect(fs.existsSync(lockPath)).toBe(false);
    expect(mockStore.upsertSentinelConfig).toHaveBeenCalledWith("registered-proj", { enabled: 0, pid: null });
  });

  it("stop reports stale lockfile cleanup when the process is already gone", async () => {
    mockListRegisteredProjects.mockResolvedValue([
      { id: "stale-lock-proj", path: "/canonical/project", name: "test" },
    ]);

    const mockStore = {
      close: vi.fn(),
      isOpen: () => true,
      logEvent: vi.fn().mockResolvedValue(undefined),
      recordSentinelRun: vi.fn().mockResolvedValue(undefined),
      updateSentinelRun: vi.fn().mockResolvedValue(undefined),
      upsertSentinelConfig: vi.fn().mockResolvedValue(undefined),
      getSentinelConfig: vi.fn().mockResolvedValue(null),
      getSentinelRuns: vi.fn().mockResolvedValue([]),
    };
    mockPostgresStoreForProject.mockReturnValue(mockStore);
    vi.spyOn(process, "kill").mockImplementation(() => { throw new Error("dead"); });
    const lockDir = path.join(homedir(), ".foreman", "sentinels");
    const lockPath = path.join(lockDir, "stale-lock-proj.lock");
    fs.mkdirSync(lockDir, { recursive: true });
    fs.writeFileSync(lockPath, JSON.stringify({ pid: 3333, startedAt: "2026-01-01T00:00:00.000Z", branch: "main", intervalMinutes: 30, testCommand: "npm test" }));

    try {
      await sentinelCommand.parseAsync(["stop", "--project", "stale-lock-proj"], { from: "user" });
    } catch {
      // exit mocked
    }

    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Process 3333 not running, cleaned up lockfile");
    expect(fs.existsSync(lockPath)).toBe(false);
  });


  it("list reports when no projects are registered", async () => {
    mockListRegisteredProjects.mockResolvedValue([]);

    try {
      await sentinelCommand.parseAsync(["list"], { from: "user" });
    } catch {
      // exit mocked
    }

    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("No projects registered. Run `foreman init` first.");
  });

  it("status text mode renders recent run rows with statuses, hashes, and durations", async () => {
    mockListRegisteredProjects.mockResolvedValue([
      { id: "status-runs-proj", path: "/canonical/project", name: "test" },
    ]);

    const mockStore = {
      close: vi.fn(),
      isOpen: () => true,
      logEvent: vi.fn().mockResolvedValue(undefined),
      recordSentinelRun: vi.fn().mockResolvedValue(undefined),
      updateSentinelRun: vi.fn().mockResolvedValue(undefined),
      upsertSentinelConfig: vi.fn().mockResolvedValue(undefined),
      getSentinelConfig: vi.fn().mockResolvedValue({ branch: "main", test_command: "npm test", interval_minutes: 30 }),
      getSentinelRuns: vi.fn().mockResolvedValue([
        { id: "run-1", status: "passed", started_at: "2026-01-01T00:00:00.000Z", completed_at: "2026-01-01T00:01:05.000Z", commit_hash: "abc12345" },
        { id: "run-2", status: "failed", started_at: "2026-01-01T01:00:00.000Z", completed_at: null, commit_hash: null },
      ]),
    };
    mockPostgresStoreForProject.mockReturnValue(mockStore);

    try {
      await sentinelCommand.parseAsync(["status", "--project", "test"], { from: "user" });
    } catch {
      // exit mocked
    }

    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Sentinel status:");
    expect(rendered).toContain("Recent runs (2):");
    expect(rendered).toContain("abc12345".slice(0, 8));
    expect(rendered).toContain("65.0s");
    expect(rendered).toContain("passed");
    expect(rendered).toContain("failed");
  });

  it("stop reports missing lockfiles and still disables sentinel config", async () => {
    mockListRegisteredProjects.mockResolvedValue([
      { id: "stop-no-lock-proj", path: "/canonical/project", name: "test" },
    ]);

    const mockStore = {
      close: vi.fn(),
      isOpen: () => true,
      logEvent: vi.fn().mockResolvedValue(undefined),
      recordSentinelRun: vi.fn().mockResolvedValue(undefined),
      updateSentinelRun: vi.fn().mockResolvedValue(undefined),
      upsertSentinelConfig: vi.fn().mockResolvedValue(undefined),
      getSentinelConfig: vi.fn().mockResolvedValue(null),
      getSentinelRuns: vi.fn().mockResolvedValue([]),
    };
    mockPostgresStoreForProject.mockReturnValue(mockStore);
    const lockPath = path.join(homedir(), ".foreman", "sentinels", "stop-no-lock-proj.lock");
    fs.rmSync(lockPath, { force: true });

    try {
      await sentinelCommand.parseAsync(["stop", "--project", "test"], { from: "user" });
    } catch {
      // exit mocked
    }

    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("No sentinel running (no lockfile found)");
    expect(mockStore.upsertSentinelConfig).toHaveBeenCalledWith("stop-no-lock-proj", { enabled: 0, pid: null });
  });

  it("list text mode renders running and stopped projects and cleans stale locks", async () => {
    mockListRegisteredProjects.mockResolvedValue([
      { id: "proj-1", name: "Project 1", path: "/path/1" },
      { id: "proj-2", name: "Project 2", path: "/path/2" },
    ]);

    const mockStore = {
      close: vi.fn(),
      isOpen: () => true,
      logEvent: vi.fn().mockResolvedValue(undefined),
      recordSentinelRun: vi.fn().mockResolvedValue(undefined),
      updateSentinelRun: vi.fn().mockResolvedValue(undefined),
      upsertSentinelConfig: vi.fn().mockResolvedValue(undefined),
      getSentinelConfig: vi.fn().mockResolvedValue({ enabled: 1 }),
      getSentinelRuns: vi.fn().mockResolvedValue([]),
    };
    mockPostgresStoreForProject.mockReturnValue(mockStore);

    const processKillSpy = vi.spyOn(process, "kill").mockImplementation((pid: number, signal?: string | number) => {
      if (signal === 0 && pid === 5678) throw new Error("dead");
      return true as never;
    });

    const lockDir = path.join(homedir(), ".foreman", "sentinels");
    const liveLockPath = path.join(lockDir, "proj-1.lock");
    const staleLockPath = path.join(lockDir, "proj-2.lock");
    fs.mkdirSync(lockDir, { recursive: true });
    fs.writeFileSync(liveLockPath, JSON.stringify({ pid: 4567, startedAt: "2026-01-01T00:00:00.000Z", branch: "main", intervalMinutes: 30, testCommand: "npm test" }));
    fs.writeFileSync(staleLockPath, JSON.stringify({ pid: 5678, startedAt: "2026-01-01T00:00:00.000Z", branch: "main", intervalMinutes: 30, testCommand: "npm test" }));

    try {
      await sentinelCommand.parseAsync(["list"], { from: "user" });
    } catch {
      // exit mocked
    } finally {
      fs.rmSync(liveLockPath, { force: true });
      fs.rmSync(staleLockPath, { force: true });
    }

    expect(processKillSpy).toHaveBeenCalledWith(4567, 0);
    expect(processKillSpy).toHaveBeenCalledWith(5678, 0);
    expect(fs.existsSync(staleLockPath)).toBe(false);
    const rendered = vi.mocked(console.log).mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Projects with Sentinel Status (2)");
    expect(rendered).toContain("Project 1");
    expect(rendered).toContain("running");
    expect(rendered).toContain("Project 2");
    expect(rendered).toContain("stopped");
  });
});
