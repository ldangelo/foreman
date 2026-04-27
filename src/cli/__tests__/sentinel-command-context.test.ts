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
    backendType: "beads",
    taskClient: { create: vi.fn() },
  });

  const mockEnsureCliPostgresPool = vi.fn();
  const mockListRegisteredProjects = vi.fn().mockResolvedValue([]);
  const mockPostgresStoreForProject = vi.fn();
  const mockResolveRepoRootProjectPath = vi.fn();
  const mockWrapPostgresSentinelStore = vi.fn();

  const mockRunOnce = vi.fn().mockResolvedValue({
    status: "passed",
    durationMs: 1,
    output: "",
    commitHash: undefined,
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
    getSentinelConfig: vi.fn().mockResolvedValue(null),
    getSentinelRuns: vi.fn().mockResolvedValue([]),
    upsertSentinelConfig: vi.fn().mockResolvedValue(undefined),
  };

  MockForemanStore.forProject = vi.fn(() => localStore);

  const MockSentinelAgent = vi.fn(function (this: Record<string, unknown>) {
    this.runOnce = mockRunOnce;
    this.start = mockStart;
    this.stop = mockStop;
  });

  const mockVcsCreate = vi.fn().mockResolvedValue({
    getRepoRoot: vi.fn(),
  });

  return {
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
    vi.spyOn(console, "warn").mockImplementation(() => {});
    vi.spyOn(process, "exit").mockImplementation(((code?: number) => code as never) as never);

    mockListRegisteredProjects.mockResolvedValue([]);
    mockEnsureCliPostgresPool.mockImplementation(() => {});
    mockResolveRepoRootProjectPath.mockResolvedValue("/mock/project");
    mockPostgresStoreForProject.mockReturnValue({
      close: vi.fn(),
      isOpen: vi.fn(() => true),
      logEvent: vi.fn().mockResolvedValue(undefined),
      recordSentinelRun: vi.fn().mockResolvedValue(undefined),
      updateSentinelRun: vi.fn().mockResolvedValue(undefined),
      upsertSentinelConfig: vi.fn().mockResolvedValue(undefined),
      getSentinelConfig: vi.fn().mockResolvedValue(null),
      getSentinelRuns: vi.fn().mockResolvedValue([]),
    });
    mockRunOnce.mockResolvedValue({
      status: "passed",
      durationMs: 1,
      output: "",
      commitHash: undefined,
    });
    mockStart.mockImplementation(() => {});
    mockStop.mockImplementation(() => {});
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it.each(["run-once", "status", "stop"])("resolves registered sentinel subcommands to the registered project path for %s", async (subcommand) => {
    mockResolveRepoRootProjectPath.mockResolvedValue("/canonical/project");
    mockListRegisteredProjects.mockResolvedValue([
      { id: "registered-proj", path: "/canonical/project", name: "test" },
    ]);

    await invokeSentinel(subcommand);

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({});
    expect(mockVcsCreate).toHaveBeenCalledWith({ backend: "auto" }, "/canonical/project");
    expect(MockForemanStore.forProject).toHaveBeenCalledWith("/canonical/project");
    expect(mockEnsureCliPostgresPool).toHaveBeenCalledWith("/canonical/project");
    expect(mockPostgresStoreForProject).toHaveBeenCalledWith("registered-proj");
    if (subcommand === "run-once") {
      expect(MockSentinelAgent).toHaveBeenCalled();
      expect(mockRunOnce).toHaveBeenCalled();
    } else {
      expect(MockSentinelAgent).not.toHaveBeenCalled();
      expect(mockRunOnce).not.toHaveBeenCalled();
    }
  });

  it.each(["run-once", "status", "stop"])("keeps local unregistered behavior unchanged for %s", async (subcommand) => {
    mockListRegisteredProjects.mockResolvedValue([]);

    await invokeSentinel(subcommand);

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({});
    expect(mockVcsCreate).toHaveBeenCalledWith({ backend: "auto" }, "/mock/project");
    expect(MockForemanStore.forProject).toHaveBeenCalledWith("/mock/project");
    expect(mockPostgresStoreForProject).not.toHaveBeenCalled();
    expect(mockEnsureCliPostgresPool).not.toHaveBeenCalled();
    if (subcommand === "run-once") {
      expect(MockSentinelAgent).toHaveBeenCalled();
      expect(mockRunOnce).toHaveBeenCalled();
    } else {
      expect(MockSentinelAgent).not.toHaveBeenCalled();
      expect(mockRunOnce).not.toHaveBeenCalled();
    }
  });

  it("routes all four sentinel subcommands through resolveRepoRootProjectPath({})", () => {
    const source = readFileSync(path.resolve(__dirname, "../commands/sentinel.ts"), "utf8");

    expect(source.match(/resolveRepoRootProjectPath\(\{\}\)/g)).toHaveLength(4);
    expect(source).not.toContain("getRepoRoot(process.cwd())");
  });

  it("keeps outside-a-repo behavior unchanged", async () => {
    mockResolveRepoRootProjectPath.mockRejectedValue(new Error("not a repo"));

    await invokeSentinel("run-once");

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({});
    expect(mockVcsCreate).not.toHaveBeenCalled();
    expect(MockForemanStore.forProject).not.toHaveBeenCalled();
    expect(mockPostgresStoreForProject).not.toHaveBeenCalled();
    expect(mockEnsureCliPostgresPool).not.toHaveBeenCalled();
    expect(mockRunOnce).not.toHaveBeenCalled();
  });
});
