import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

  const {
    mockCreateTaskClient,
    mockListRegisteredProjects,
    mockResolveRepoRootProjectPath,
    mockGetProjectByPath,
    mockLocalGetRun,
    mockSyncBeadStatusAfterMerge,
    mockCreateVcsBackend,
    MockForemanStore,
    MockPostgresStore,
    MockRefinery,
    MockMergeQueue,
  MockPostgresMergeQueue,
  MockMergeCostTracker,
  MockPostgresMergeCostTracker,
  } = vi.hoisted(() => {
  const mockCreateTaskClient = vi.fn().mockResolvedValue({ taskClient: { kind: "task-client" }, backendType: "native" });
  const mockListRegisteredProjects = vi.fn().mockResolvedValue([]);
  const mockResolveRepoRootProjectPath = vi.fn().mockResolvedValue("/mock/project");
  const mockGetProjectByPath = vi.fn().mockReturnValue({ id: "proj-local", path: "/mock/project" });
  const mockLocalGetRun = vi.fn().mockReturnValue(null);
  const mockSyncBeadStatusAfterMerge = vi.fn().mockResolvedValue(undefined);
  const mockCreateVcsBackend = vi.fn().mockResolvedValue({
    name: "git",
    getRepoRoot: vi.fn().mockResolvedValue("/mock/project"),
    detectDefaultBranch: vi.fn().mockResolvedValue("main"),
  });

  const MockForemanStore = vi.fn(function MockForemanStoreImpl(this: Record<string, unknown>) {
    this.getProjectByPath = mockGetProjectByPath;
    this.getRun = mockLocalGetRun;
    this.getDb = vi.fn().mockReturnValue({});
    this.close = vi.fn();
  }) as ReturnType<typeof vi.fn> & { forProject: ReturnType<typeof vi.fn> };
  MockForemanStore.forProject = vi.fn((...args: unknown[]) => new MockForemanStore(...args));

  const MockPostgresStore = vi.fn(function MockPostgresStoreImpl(this: Record<string, unknown>) {
    this.getRun = vi.fn();
    this.getRunsByStatus = vi.fn();
    this.getRunsByStatuses = vi.fn();
    this.getRunsByBaseBranch = vi.fn();
  });

  const MockRefinery = vi.fn(function MockRefineryImpl(this: Record<string, unknown>, ...args: unknown[]) {
    this.args = args;
    this.mergeCompleted = vi.fn();
    this.resolveConflict = vi.fn();
  });

  const MockMergeQueue = vi.fn(function MockMergeQueueImpl(this: Record<string, unknown>) {
    this.reconcile = vi.fn().mockResolvedValue({ enqueued: 0, skipped: 0, invalidBranch: 0, failedToEnqueue: [] });
    this.list = vi.fn().mockResolvedValue([]);
    this.resetForRetry = vi.fn().mockResolvedValue(true);
    this.dequeue = vi.fn().mockResolvedValue(null);
    this.updateStatus = vi.fn().mockResolvedValue(undefined);
    this.getRetryableEntries = vi.fn().mockResolvedValue([]);
    this.reEnqueue = vi.fn().mockResolvedValue(false);
  });

  const MockPostgresMergeQueue = vi.fn(function MockPostgresMergeQueueImpl(this: Record<string, unknown>) {
    this.reconcile = vi.fn().mockResolvedValue({ enqueued: 0, skipped: 0, invalidBranch: 0, failedToEnqueue: [] });
    this.list = vi.fn().mockResolvedValue([]);
    this.resetForRetry = vi.fn().mockResolvedValue(true);
    this.dequeue = vi.fn().mockResolvedValue(null);
    this.updateStatus = vi.fn().mockResolvedValue(undefined);
    this.getRetryableEntries = vi.fn().mockResolvedValue([]);
    this.reEnqueue = vi.fn().mockResolvedValue(false);
  });

  const MockMergeCostTracker = vi.fn(function MockMergeCostTrackerImpl(this: Record<string, unknown>) {
    this.getStats = vi.fn().mockResolvedValue({
      totalCostUsd: 0,
      totalInputTokens: 0,
      totalOutputTokens: 0,
      entryCount: 0,
      byTier: {},
      byModel: {},
    });
    this.getResolutionRate = vi.fn().mockResolvedValue({ total: 0, successes: 0, rate: 0 });
  });

  const MockPostgresMergeCostTracker = vi.fn(function MockPostgresMergeCostTrackerImpl(this: Record<string, unknown>) {
    this.getStats = vi.fn().mockResolvedValue({
      totalCostUsd: 0,
      totalInputTokens: 0,
      totalOutputTokens: 0,
      entryCount: 0,
      byTier: {},
      byModel: {},
    });
    this.getResolutionRate = vi.fn().mockResolvedValue({ total: 0, successes: 0, rate: 0 });
  });

  return {
    mockCreateTaskClient,
    mockListRegisteredProjects,
    mockResolveRepoRootProjectPath,
    mockGetProjectByPath,
    mockLocalGetRun,
    mockSyncBeadStatusAfterMerge,
    mockCreateVcsBackend,
    MockForemanStore,
    MockPostgresStore,
    MockRefinery,
    MockMergeQueue,
    MockPostgresMergeQueue,
    MockMergeCostTracker,
    MockPostgresMergeCostTracker,
  };
});

vi.mock("../../lib/task-client-factory.js", () => ({
  createTaskClient: mockCreateTaskClient,
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: MockForemanStore,
}));

vi.mock("../../lib/postgres-store.js", () => ({
  PostgresStore: MockPostgresStore,
}));

vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: mockCreateVcsBackend,
  },
}));

vi.mock("../../orchestrator/refinery.js", () => ({
  Refinery: MockRefinery,
  dryRunMerge: vi.fn(),
}));

vi.mock("../../orchestrator/auto-merge.js", () => ({
  syncBeadStatusAfterMerge: mockSyncBeadStatusAfterMerge,
}));

vi.mock("../../orchestrator/merge-queue.js", () => ({
  MergeQueue: MockMergeQueue,
}));

vi.mock("../../orchestrator/postgres-merge-queue.js", () => ({
  PostgresMergeQueue: MockPostgresMergeQueue,
}));

vi.mock("../../orchestrator/merge-cost-tracker.js", () => ({
  MergeCostTracker: MockMergeCostTracker,
}));

vi.mock("../../orchestrator/postgres-merge-cost-tracker.js", () => ({
  PostgresMergeCostTracker: MockPostgresMergeCostTracker,
}));

vi.mock("../commands/project-task-support.js", () => ({
  listRegisteredProjects: () => mockListRegisteredProjects(),
  resolveRepoRootProjectPath: (...args: unknown[]) => mockResolveRepoRootProjectPath(...args),
}));

import { mergeCommand } from "../commands/merge.js";

async function runCommand(args: string[]): Promise<void> {
  await mergeCommand.parseAsync(["node", "foreman", ...args]);
}

describe("merge command registered context", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockGetProjectByPath.mockReturnValue({ id: "proj-local", path: "/mock/project" });
    mockLocalGetRun.mockReturnValue(null);
    mockCreateTaskClient.mockResolvedValue({ taskClient: { kind: "task-client" }, backendType: "native" });
    mockListRegisteredProjects.mockResolvedValue([]);
    mockResolveRepoRootProjectPath.mockResolvedValue("/mock/project");
    mockSyncBeadStatusAfterMerge.mockResolvedValue(undefined);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("resolves registered merge bootstrap to the canonical project path before lookup", async () => {
    mockResolveRepoRootProjectPath.mockResolvedValue("/canonical/project");
    mockListRegisteredProjects.mockResolvedValue([{ id: "proj-1", name: "my-project", path: "/canonical/project" }]);

    await runCommand(["--stats"]);

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({});
    expect(mockCreateVcsBackend).toHaveBeenCalledWith({ backend: "auto" }, "/canonical/project");
    expect(mockCreateTaskClient).toHaveBeenCalledWith("/canonical/project", {
      ensureBrInstalled: true,
      registeredProjectId: "proj-1",
    });
    expect(MockPostgresStore).toHaveBeenCalledWith("proj-1");
    expect(MockRefinery).toHaveBeenCalledWith(
      expect.any(Object),
      expect.any(Object),
      "/canonical/project",
      expect.any(Object),
      expect.objectContaining({
        registeredProjectId: "proj-1",
        runLookup: MockPostgresStore.mock.results[0].value,
      }),
    );
    expect(MockPostgresMergeQueue).toHaveBeenCalledWith("proj-1");
    expect(MockMergeQueue).not.toHaveBeenCalled();
    expect(MockMergeCostTracker).not.toHaveBeenCalled();
    expect(MockPostgresMergeCostTracker).toHaveBeenCalledWith("proj-1");
  });

  it("does not fail when the registered project exists but the local store row is missing", async () => {
    mockGetProjectByPath.mockReturnValue(null);
    mockListRegisteredProjects.mockResolvedValue([{ id: "proj-1", name: "my-project", path: "/mock/project" }]);

    await expect(runCommand([])).resolves.toBeUndefined();

    expect(MockPostgresMergeQueue).toHaveBeenCalledWith("proj-1");
    expect(MockMergeQueue).not.toHaveBeenCalled();
    expect(MockRefinery).toHaveBeenCalled();
  });

  it("keeps local merge behavior unchanged when the project is not registered", async () => {
    await runCommand(["--stats"]);

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({});
    expect(mockCreateVcsBackend).toHaveBeenCalledWith({ backend: "auto" }, "/mock/project");
    expect(mockCreateTaskClient).toHaveBeenCalledWith("/mock/project", {
      ensureBrInstalled: true,
      registeredProjectId: undefined,
    });
    expect(MockPostgresStore).not.toHaveBeenCalled();
    expect(MockRefinery).toHaveBeenCalledWith(
      expect.any(Object),
      expect.any(Object),
      "/mock/project",
      expect.any(Object),
    );
    expect(MockMergeQueue).toHaveBeenCalledTimes(1);
    expect(MockPostgresMergeQueue).not.toHaveBeenCalled();
    expect(MockMergeCostTracker).toHaveBeenCalledWith(expect.any(Object));
    expect(MockPostgresMergeCostTracker).not.toHaveBeenCalled();
  });

  it("keeps outside-a-repo behavior unchanged", async () => {
    mockResolveRepoRootProjectPath.mockRejectedValue(new Error("not a repo"));
    const exitSpy = vi.spyOn(process, "exit").mockImplementation(((code?: number) => code as never) as never);

    await runCommand(["--stats"]);

    expect(mockResolveRepoRootProjectPath).toHaveBeenCalledWith({});
    expect(mockCreateVcsBackend).not.toHaveBeenCalled();
    expect(mockCreateTaskClient).not.toHaveBeenCalled();
    expect(MockForemanStore.forProject).not.toHaveBeenCalled();
    expect(exitSpy).toHaveBeenCalledWith(1);
  });

  it("uses the registered run lookup for --resolve without local SQLite", async () => {
    mockListRegisteredProjects.mockResolvedValue([{ id: "proj-1", name: "my-project", path: "/mock/project" }]);
    mockGetProjectByPath.mockReturnValue({ id: "proj-local", path: "/mock/project" });
    mockLocalGetRun.mockReturnValue(null);
    MockPostgresStore.mockImplementationOnce(function MockPostgresStoreImpl(this: Record<string, unknown>) {
      this.getRun = vi.fn().mockResolvedValue({ id: "run-1", seed_id: "seed-1", status: "conflict" });
      this.getRunsByStatus = vi.fn();
      this.getRunsByStatuses = vi.fn();
      this.getRunsByBaseBranch = vi.fn();
    });
    MockRefinery.mockImplementationOnce(function MockRefineryImpl(this: Record<string, unknown>) {
      this.mergeCompleted = vi.fn();
      this.resolveConflict = vi.fn().mockResolvedValue(true);
    });

    await runCommand(["--resolve", "run-1", "--strategy", "theirs"]);

    expect(mockLocalGetRun).not.toHaveBeenCalled();
    expect(MockPostgresStore).toHaveBeenCalledWith("proj-1");
    expect(MockRefinery.mock.results[0]?.value.resolveConflict).toHaveBeenCalledWith(
      "run-1",
      "theirs",
      expect.objectContaining({ targetBranch: "main" }),
    );
  });

  it("passes the registered project id through the main dequeue and auto-retry loops", async () => {
    mockListRegisteredProjects.mockResolvedValue([{ id: "proj-1", name: "my-project", path: "/mock/project" }]);

    const mainEntry = {
      id: 1,
      branch_name: "foreman/seed-1",
      seed_id: "seed-1",
      run_id: "run-1",
      enqueued_at: new Date().toISOString(),
      status: "pending" as const,
      files_modified: [],
      error: null,
      retry_count: 0,
    };
    const retryEntry = {
      id: 2,
      branch_name: "foreman/seed-2",
      seed_id: "seed-2",
      run_id: "run-2",
      enqueued_at: new Date().toISOString(),
      status: "failed" as const,
      files_modified: [],
      error: null,
      retry_count: 1,
    };
    mockLocalGetRun.mockImplementation((runId: string) => ({ id: runId, seed_id: runId.replace("run-", "seed-"), status: "completed" }));
    MockRefinery.mockImplementationOnce(function MockRefineryImpl(this: Record<string, unknown>) {
      this.resolveConflict = vi.fn();
      this.mergeCompleted = vi.fn().mockResolvedValue({
        merged: [{ seedId: "seed-1", branchName: "foreman/seed-1" }],
        conflicts: [],
        testFailures: [],
        prsCreated: [],
      });
    });
    MockPostgresMergeQueue.mockImplementationOnce(function MockPostgresMergeQueueImpl(this: Record<string, unknown>) {
      this.reconcile = vi.fn().mockResolvedValue({ enqueued: 0, skipped: 0, invalidBranch: 0, failedToEnqueue: [] });
      this.list = vi.fn().mockResolvedValue([]);
      this.resetForRetry = vi.fn().mockResolvedValue(true);
      this.dequeue = vi.fn()
        .mockResolvedValueOnce(mainEntry)
        .mockResolvedValueOnce(null)
        .mockResolvedValueOnce(retryEntry)
        .mockResolvedValueOnce(null);
      this.updateStatus = vi.fn().mockResolvedValue(undefined);
      this.getRetryableEntries = vi.fn().mockResolvedValue([retryEntry]);
      this.reEnqueue = vi.fn().mockResolvedValue(true);
    });

    await runCommand(["--auto-retry"]);

    expect(MockRefinery.mock.results[0]?.value.mergeCompleted).toHaveBeenCalledTimes(2);
    expect(MockRefinery.mock.results[0]?.value.mergeCompleted.mock.calls.map(([opts]: [Record<string, unknown>]) => opts.projectId)).toEqual([
      "proj-1",
      "proj-1",
    ]);
    expect(mockSyncBeadStatusAfterMerge.mock.calls).toEqual([
      [expect.any(Object), expect.any(Object), "run-1", "seed-1", "/mock/project", undefined, MockPostgresStore.mock.results[0].value],
      [expect.any(Object), expect.any(Object), "run-2", "seed-2", "/mock/project", undefined, MockPostgresStore.mock.results[0].value],
    ]);
  });

  it("does not depend on local runs during registered auto-retry and still syncs with runLookup", async () => {
    mockGetProjectByPath.mockReturnValue(null);
    mockListRegisteredProjects.mockResolvedValue([{ id: "proj-1", name: "my-project", path: "/mock/project" }]);

    const retryEntry = {
      id: 3,
      branch_name: "foreman/seed-3",
      seed_id: "seed-3",
      run_id: "run-3",
      enqueued_at: new Date().toISOString(),
      status: "failed" as const,
      files_modified: [],
      error: null,
      retry_count: 2,
    };

    mockLocalGetRun.mockReturnValue(null);
    MockRefinery.mockImplementationOnce(function MockRefineryImpl(this: Record<string, unknown>) {
      this.resolveConflict = vi.fn();
      this.mergeCompleted = vi.fn().mockResolvedValue({
        merged: [{ seedId: "seed-3", branchName: "foreman/seed-3" }],
        conflicts: [],
        testFailures: [],
        prsCreated: [],
      });
    });
    MockPostgresMergeQueue.mockImplementationOnce(function MockPostgresMergeQueueImpl(this: Record<string, unknown>) {
      this.reconcile = vi.fn().mockResolvedValue({ enqueued: 0, skipped: 0, invalidBranch: 0, failedToEnqueue: [] });
      this.list = vi.fn().mockResolvedValue([]);
      this.resetForRetry = vi.fn().mockResolvedValue(true);
      this.dequeue = vi.fn().mockResolvedValueOnce(retryEntry).mockResolvedValueOnce(null);
      this.updateStatus = vi.fn().mockResolvedValue(undefined);
      this.getRetryableEntries = vi.fn().mockResolvedValue([retryEntry]);
      this.reEnqueue = vi.fn().mockResolvedValue(true);
    });

    await runCommand(["--auto-retry"]);

    expect(mockLocalGetRun).toHaveBeenCalledWith("run-3");
    expect(mockSyncBeadStatusAfterMerge).toHaveBeenCalledWith(
      expect.any(Object),
      expect.any(Object),
      "run-3",
      "seed-3",
      "/mock/project",
      undefined,
      MockPostgresStore.mock.results[0].value,
    );
    expect(MockRefinery.mock.results[0]?.value.mergeCompleted).toHaveBeenCalledWith(
      expect.objectContaining({
        projectId: "proj-1",
        seedId: "seed-3",
        overrideRun: undefined,
      }),
    );
  });

  it("keeps local resolve and dequeue behavior unchanged when the project is not registered", async () => {
    const localConflictRun = { id: "run-1", seed_id: "seed-1", status: "conflict" };
    mockLocalGetRun.mockReturnValue(localConflictRun);
    MockRefinery.mockImplementationOnce(function MockRefineryImpl(this: Record<string, unknown>) {
      this.mergeCompleted = vi.fn();
      this.resolveConflict = vi.fn().mockResolvedValue(true);
    });

    await runCommand(["--resolve", "run-1", "--strategy", "theirs"]);

    expect(mockLocalGetRun).toHaveBeenCalledWith("run-1");
    expect(MockPostgresStore).not.toHaveBeenCalled();
    expect(MockRefinery.mock.results[0]?.value.resolveConflict).toHaveBeenCalled();

    vi.clearAllMocks();
    mockGetProjectByPath.mockReturnValue({ id: "proj-local", path: "/mock/project" });
    mockLocalGetRun.mockReturnValue({ id: "run-2", seed_id: "seed-2", status: "completed" });
    MockRefinery.mockImplementationOnce(function MockRefineryImpl(this: Record<string, unknown>) {
      this.resolveConflict = vi.fn();
      this.mergeCompleted = vi.fn().mockResolvedValue({
        merged: [{ seedId: "seed-2", branchName: "foreman/seed-2" }],
        conflicts: [],
        testFailures: [],
        prsCreated: [],
      });
    });
    MockMergeQueue.mockImplementationOnce(function MockMergeQueueImpl(this: Record<string, unknown>) {
      this.reconcile = vi.fn().mockResolvedValue({ enqueued: 0, skipped: 0, invalidBranch: 0, failedToEnqueue: [] });
      this.list = vi.fn().mockResolvedValue([]);
      this.resetForRetry = vi.fn().mockResolvedValue(true);
      this.dequeue = vi.fn()
        .mockResolvedValueOnce({
          id: 1,
          branch_name: "foreman/seed-2",
          seed_id: "seed-2",
          run_id: "run-2",
          enqueued_at: new Date().toISOString(),
          status: "pending",
          files_modified: [],
          error: null,
          retry_count: 0,
        })
        .mockResolvedValueOnce(null);
      this.updateStatus = vi.fn().mockResolvedValue(undefined);
      this.getRetryableEntries = vi.fn().mockResolvedValue([]);
      this.reEnqueue = vi.fn().mockResolvedValue(false);
    });

    await runCommand([]);

    expect(MockRefinery.mock.results[0]?.value.mergeCompleted).toHaveBeenCalledWith(
      expect.objectContaining({ projectId: "proj-local" }),
    );
    expect(mockSyncBeadStatusAfterMerge).toHaveBeenCalledWith(
      expect.any(Object),
      expect.any(Object),
      "run-2",
      "seed-2",
      "/mock/project",
      undefined,
      undefined,
    );
  });
});
