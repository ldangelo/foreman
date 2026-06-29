import { readFileSync } from "node:fs";
import path from "node:path";
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

const originalBackend = process.env.FOREMAN_BACKEND;

async function invokeSentinel(subcommand: string): Promise<void> {
  await sentinelCommand.parseAsync([subcommand], { from: "user" });
}

describe("sentinel command store context", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(process, "exit").mockImplementation((() => {}) as () => never);

    process.env.FOREMAN_BACKEND = "node";

    // Default: no registered projects
    mockListRegisteredProjects.mockResolvedValue([]);
    mockResolveRepoRootProjectPath.mockResolvedValue("/mock/project");
  });

  afterEach(() => {
    if (originalBackend === undefined) delete process.env.FOREMAN_BACKEND;
    else process.env.FOREMAN_BACKEND = originalBackend;
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
    const source = readFileSync(path.resolve(__dirname, "../commands/sentinel.ts"), "utf8");

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
it("lists sentinel compatibility in Elixir mode without legacy stores", async () => {
  delete process.env.FOREMAN_BACKEND;
  mockListRegisteredProjects.mockResolvedValue([
    { id: "proj-1", path: "/repo", name: "demo" },
  ]);
  const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});

  await sentinelCommand.parseAsync(["list", "--json"], { from: "user" });

  expect(MockForemanStore.forProject).not.toHaveBeenCalled();
  expect(mockPostgresStoreForProject).not.toHaveBeenCalled();
  const output = String(logSpy.mock.calls[0][0]);
  expect(JSON.parse(output)[0].sentinel.mode).toBe("elixir-scheduler");
});

});
