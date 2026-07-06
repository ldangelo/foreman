import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

  const {
    mockCreateTaskClient,
    mockListRegisteredProjects,
    mockResolveRepoRootProjectPath,
    mockEnsureCliPostgresPool,
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
  const mockEnsureCliPostgresPool = vi.fn();
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
    mockEnsureCliPostgresPool,
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
  ensureCliPostgresPool: (...args: unknown[]) => mockEnsureCliPostgresPool(...args),
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
    expect(mockEnsureCliPostgresPool).toHaveBeenCalledWith("/canonical/project");
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
      registeredProjectId: undefined,
    });
    expect(mockEnsureCliPostgresPool).not.toHaveBeenCalled();
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

  it("uses the registered run lookup for --resolve without local Postgres", async () => {
    mockListRegisteredProjects.mockResolvedValue([{ id: "proj-1", name: "my-project", path: "/mock/project" }]);
    mockGetProjectByPath.mockReturnValue({ id: "proj-local", path: "/mock/project" });
    mockLocalGetRun.mockReturnValue(null);
    MockPostgresStore.mockImplementationOnce(function MockPostgresStoreImpl(this: Record<string, unknown>) {
      this.getRun = vi.fn().mockResolvedValue({ id: "run-1", task_id: "task-1", status: "conflict" });
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
      branch_name: "foreman/task-1",
      task_id: "task-1",
      run_id: "run-1",
      enqueued_at: new Date().toISOString(),
      status: "pending" as const,
      files_modified: [],
      error: null,
      retry_count: 0,
    };
    const retryEntry = {
      id: 2,
      branch_name: "foreman/task-2",
      task_id: "task-2",
      run_id: "run-2",
      enqueued_at: new Date().toISOString(),
      status: "failed" as const,
      files_modified: [],
      error: null,
      retry_count: 1,
    };
    mockLocalGetRun.mockImplementation((runId: string) => ({ id: runId, task_id: runId.replace("run-", "task-"), status: "completed" }));
    MockRefinery.mockImplementationOnce(function MockRefineryImpl(this: Record<string, unknown>) {
      this.resolveConflict = vi.fn();
      this.mergeCompleted = vi.fn().mockResolvedValue({
        merged: [{ taskId: "task-1", branchName: "foreman/task-1" }],
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
      [expect.any(Object), expect.any(Object), "run-1", "task-1", "/mock/project", undefined, MockPostgresStore.mock.results[0].value],
      [expect.any(Object), expect.any(Object), "run-2", "task-2", "/mock/project", undefined, MockPostgresStore.mock.results[0].value],
    ]);
  });

  it("does not depend on local runs during registered auto-retry and still syncs with runLookup", async () => {
    mockGetProjectByPath.mockReturnValue(null);
    mockListRegisteredProjects.mockResolvedValue([{ id: "proj-1", name: "my-project", path: "/mock/project" }]);

    const retryEntry = {
      id: 3,
      branch_name: "foreman/task-3",
      task_id: "task-3",
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
        merged: [{ taskId: "task-3", branchName: "foreman/task-3" }],
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
      "task-3",
      "/mock/project",
      undefined,
      MockPostgresStore.mock.results[0].value,
    );
    expect(MockRefinery.mock.results[0]?.value.mergeCompleted).toHaveBeenCalledWith(
      expect.objectContaining({
        projectId: "proj-1",
        taskId: "task-3",
        overrideRun: undefined,
      }),
    );
  });

  it("keeps local resolve and dequeue behavior unchanged when the project is not registered", async () => {
    const localConflictRun = { id: "run-1", task_id: "task-1", status: "conflict" };
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
    mockLocalGetRun.mockReturnValue({ id: "run-2", task_id: "task-2", status: "completed" });
    MockRefinery.mockImplementationOnce(function MockRefineryImpl(this: Record<string, unknown>) {
      this.resolveConflict = vi.fn();
      this.mergeCompleted = vi.fn().mockResolvedValue({
        merged: [{ taskId: "task-2", branchName: "foreman/task-2" }],
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
          branch_name: "foreman/task-2",
          task_id: "task-2",
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
      "task-2",
      "/mock/project",
      undefined,
      undefined,
    );
  });

  it("requires --strategy when using --resolve", async () => {
    const exitSpy = vi.spyOn(process, "exit").mockImplementation(((code?: number) => code as never) as never);
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);

    await runCommand(["--resolve", "run-1"]);

    expect(exitSpy).toHaveBeenCalledWith(1);
    expect(errorSpy).toHaveBeenCalledWith(expect.stringContaining("--strategy <theirs|abort> is required"));
  });

  it("rejects invalid --strategy values for --resolve", async () => {
    const exitSpy = vi.spyOn(process, "exit").mockImplementation(((code?: number) => code as never) as never);
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);

    await runCommand(["--resolve", "run-1", "--strategy", "ours"]);

    expect(exitSpy).toHaveBeenCalledWith(1);
    expect(errorSpy).toHaveBeenCalledWith(expect.stringContaining("Invalid strategy 'ours'"));
  });

  it("dry-run exits early when the queue is empty", async () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    await runCommand(["--dry-run"]);

    expect(MockRefinery.mock.results[0]?.value.mergeCompleted).not.toHaveBeenCalled();
    expect(logSpy).toHaveBeenCalledWith(expect.stringContaining("No branches in merge queue to preview."));
  });

  it("reports when --resolve cannot find the requested run", async () => {
    mockLocalGetRun.mockReturnValue(null);
    const exitSpy = vi.spyOn(process, "exit").mockImplementation(((code?: number) => code as never) as never);
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);

    await runCommand(["--resolve", "run-missing", "--strategy", "theirs"]);

    expect(exitSpy).toHaveBeenCalledWith(1);
    expect(errorSpy).toHaveBeenCalledWith(expect.stringContaining("Run 'run-missing' not found."));
  });

  it("rejects --resolve for runs that are not in conflict state", async () => {
    mockLocalGetRun.mockReturnValue({ id: "run-1", task_id: "task-1", status: "completed" });
    const exitSpy = vi.spyOn(process, "exit").mockImplementation(((code?: number) => code as never) as never);
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);

    await runCommand(["--resolve", "run-1", "--strategy", "theirs"]);

    expect(exitSpy).toHaveBeenCalledWith(1);
    expect(errorSpy).toHaveBeenCalledWith(expect.stringContaining("is not in conflict state"));
  });

  it("prints success output when --resolve merges cleanly", async () => {
    mockLocalGetRun.mockReturnValue({ id: "run-1", task_id: "task-1", status: "conflict" });
    MockRefinery.mockImplementationOnce(function MockRefineryImpl(this: Record<string, unknown>) {
      this.mergeCompleted = vi.fn();
      this.resolveConflict = vi.fn().mockResolvedValue(true);
    });
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    await runCommand(["--resolve", "run-1", "--strategy", "theirs"]);

    const rendered = logSpy.mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Resolving conflict for task-1");
    expect(rendered).toContain("merged successfully");
  });

  it("prints abort output when --resolve aborts after an unresolved conflict", async () => {
    mockLocalGetRun.mockReturnValue({ id: "run-1", task_id: "task-1", status: "conflict" });
    MockRefinery.mockImplementationOnce(function MockRefineryImpl(this: Record<string, unknown>) {
      this.mergeCompleted = vi.fn();
      this.resolveConflict = vi.fn().mockResolvedValue(false);
    });
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    await runCommand(["--resolve", "run-1", "--strategy", "abort"]);

    const rendered = logSpy.mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Merge aborted");
    expect(rendered).toContain("marked as failed");
  });

  it("prints failure output when --resolve with theirs still fails", async () => {
    mockLocalGetRun.mockReturnValue({ id: "run-1", task_id: "task-1", status: "conflict" });
    MockRefinery.mockImplementationOnce(function MockRefineryImpl(this: Record<string, unknown>) {
      this.mergeCompleted = vi.fn();
      this.resolveConflict = vi.fn().mockResolvedValue(false);
    });
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    await runCommand(["--resolve", "run-1", "--strategy", "theirs"]);

    const rendered = logSpy.mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Failed to resolve conflict for task-1");
    expect(rendered).toContain("marked as failed");
  });

  it("lists queue entries as JSON", async () => {
    MockMergeQueue.mockImplementationOnce(function MockMergeQueueImpl(this: Record<string, unknown>) {
      this.reconcile = vi.fn().mockResolvedValue({ enqueued: 0, skipped: 0, invalidBranch: 0, failedToEnqueue: [] });
      this.list = vi.fn().mockResolvedValue([
        {
          id: 1,
          branch_name: "foreman/task-1",
          task_id: "task-1",
          run_id: "run-1",
          enqueued_at: new Date().toISOString(),
          status: "pending",
          files_modified: ["a.ts"],
          error: null,
          retry_count: 0,
        },
      ]);
      this.resetForRetry = vi.fn();
      this.dequeue = vi.fn();
      this.updateStatus = vi.fn();
      this.getRetryableEntries = vi.fn().mockResolvedValue([]);
      this.reEnqueue = vi.fn().mockResolvedValue(false);
    });
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    await runCommand(["--list", "--json"]);

    const parsed = JSON.parse(String(logSpy.mock.calls[0]?.[0] ?? "{}"));
    expect(parsed.entries).toHaveLength(1);
    expect(parsed.entries[0]).toMatchObject({ task_id: "task-1", run_id: "run-1" });
  });

  it("lists queue entries with reconcile banner in text mode", async () => {
    MockMergeQueue.mockImplementationOnce(function MockMergeQueueImpl(this: Record<string, unknown>) {
      this.reconcile = vi.fn().mockResolvedValue({ enqueued: 2, skipped: 0, invalidBranch: 0, failedToEnqueue: [] });
      this.list = vi.fn().mockResolvedValue([
        {
          id: 1,
          branch_name: "foreman/task-1",
          task_id: "task-1",
          run_id: "run-1",
          enqueued_at: new Date(Date.now() - 60_000).toISOString(),
          status: "pending",
          files_modified: ["a.ts", "b.ts"],
          error: "merge blocked",
          retry_count: 0,
        },
      ]);
      this.resetForRetry = vi.fn();
      this.dequeue = vi.fn();
      this.updateStatus = vi.fn();
      this.getRetryableEntries = vi.fn().mockResolvedValue([]);
      this.reEnqueue = vi.fn().mockResolvedValue(false);
    });
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    await runCommand(["--list"]);

    const rendered = logSpy.mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("reconciled 2 new entry/entries into queue");
    expect(rendered).toContain("Merge queue (1 entries)");
    expect(rendered).toContain("task-1");
    expect(rendered).toContain("merge blocked");
    expect(rendered).toContain("Merge all:");
    expect(rendered).toContain("Merge one:");
  });

  it("prints a JSON error when no project is registered and --json is used", async () => {
    mockGetProjectByPath.mockReturnValue(null);
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const exitSpy = vi.spyOn(process, "exit").mockImplementation(((code?: number) => code as never) as never);

    await runCommand(["--json"]);

    const parsed = JSON.parse(String(errorSpy.mock.calls[0]?.[0] ?? "{}"));
    expect(parsed).toEqual({ error: "No project registered. Run 'foreman init' first." });
    expect(exitSpy).toHaveBeenCalledWith(1);
  });

  it("lists an empty merge queue as JSON", async () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    await runCommand(["--list", "--json"]);

    const parsed = JSON.parse(String(logSpy.mock.calls[0]?.[0] ?? "{}"));
    expect(parsed).toEqual({ entries: [] });
  });

  it("prints the empty merge queue message in text mode", async () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    await runCommand(["--list"]);

    expect(logSpy).toHaveBeenCalledWith(expect.stringContaining("No beads in merge queue."));
  });

  it("prints branch-missing reconcile warnings before reporting no completed tasks", async () => {
    MockMergeQueue.mockImplementationOnce(function MockMergeQueueImpl(this: Record<string, unknown>) {
      this.reconcile = vi.fn().mockResolvedValue({
        enqueued: 0,
        skipped: 0,
        invalidBranch: 0,
        failedToEnqueue: [{ run_id: "run-1", task_id: "task-1", reason: "branch missing" }],
      });
      this.list = vi.fn().mockResolvedValue([]);
      this.resetForRetry = vi.fn().mockResolvedValue(true);
      this.dequeue = vi.fn().mockResolvedValue(null);
      this.updateStatus = vi.fn().mockResolvedValue(undefined);
      this.getRetryableEntries = vi.fn().mockResolvedValue([]);
      this.reEnqueue = vi.fn().mockResolvedValue(false);
    });
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    await runCommand([]);

    const rendered = logSpy.mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("could not be enqueued");
    expect(rendered).toContain("task-1: branch missing");
    expect(rendered).toContain("No completed tasks to merge.");
  });

  it("prints the task-filter empty-state guidance when no completed run is found", async () => {
    MockMergeQueue.mockImplementationOnce(function MockMergeQueueImpl(this: Record<string, unknown>) {
      this.reconcile = vi.fn().mockResolvedValue({ enqueued: 0, skipped: 0, invalidBranch: 0, failedToEnqueue: [] });
      this.list = vi.fn().mockResolvedValue([]);
      this.resetForRetry = vi.fn().mockResolvedValue(true);
      this.dequeue = vi.fn().mockResolvedValue(null);
      this.updateStatus = vi.fn().mockResolvedValue(undefined);
      this.getRetryableEntries = vi.fn().mockResolvedValue([]);
      this.reEnqueue = vi.fn().mockResolvedValue(false);
    });
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    await runCommand(["--task", "task-404"]);

    const rendered = logSpy.mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("No completed run found for task task-404.");
    expect(rendered).toContain("Use 'foreman merge --list' to see tasks ready to merge.");
  });

  it("prints PR and test-failure summaries from the main merge loop", async () => {
    mockLocalGetRun.mockReturnValue({ id: "run-1", task_id: "task-1", status: "completed" });
    MockRefinery.mockImplementationOnce(function MockRefineryImpl(this: Record<string, unknown>) {
      this.resolveConflict = vi.fn();
      this.mergeCompleted = vi.fn()
        .mockResolvedValueOnce({
          merged: [],
          conflicts: [],
          testFailures: [],
          prsCreated: [{ taskId: "task-1", branchName: "foreman/task-1", prUrl: "https://example.test/pr/1" }],
        })
        .mockResolvedValueOnce({
          merged: [],
          conflicts: [],
          testFailures: [{ runId: "run-2", taskId: "task-2", branchName: "foreman/task-2", error: "tests blew up\nstack" }],
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
          branch_name: "foreman/task-1",
          task_id: "task-1",
          run_id: "run-1",
          enqueued_at: new Date().toISOString(),
          status: "pending",
          files_modified: [],
          error: null,
          retry_count: 0,
        })
        .mockResolvedValueOnce({
          id: 2,
          branch_name: "foreman/task-2",
          task_id: "task-2",
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
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    await runCommand([]);

    const rendered = logSpy.mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("PRs created for 1 conflicting task(s)");
    expect(rendered).toContain("https://example.test/pr/1");
    expect(rendered).toContain("Test failures in 1 task(s)");
    expect(rendered).toContain("tests blew up");
  });

  it("prints detailed stats output including tier, model, and resolution rate", async () => {
    MockMergeCostTracker.mockImplementationOnce(function MockMergeCostTrackerImpl(this: Record<string, unknown>) {
      this.getStats = vi.fn().mockResolvedValue({
        totalCostUsd: 12.3456,
        totalInputTokens: 1234,
        totalOutputTokens: 567,
        entryCount: 3,
        byTier: { "1": { count: 2, totalCostUsd: 10.5 } },
        byModel: { "claude-sonnet": { count: 3, totalCostUsd: 12.3456 } },
      });
      this.getResolutionRate = vi.fn().mockResolvedValue({ total: 4, successes: 3, rate: 75 });
    });
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    await runCommand(["--stats", "weekly"]);

    const rendered = logSpy.mock.calls.map((args) => String(args[0] ?? "")).join("\n");
    expect(rendered).toContain("Merge cost statistics (weekly)");
    expect(rendered).toContain("Total cost:     $12.3456");
    expect(rendered).toContain("By tier:");
    expect(rendered).toContain("Tier 1: 2 calls, $10.5000");
    expect(rendered).toContain("By model:");
    expect(rendered).toContain("claude-sonnet: 3 calls, $12.3456");
    expect(rendered).toContain("AI resolution rate (30 days):");
    expect(rendered).toContain("3/4 conflicts (75.0%)");
  });

  it("prints stats as JSON when --stats and --json are combined", async () => {
    MockMergeCostTracker.mockImplementationOnce(function MockMergeCostTrackerImpl(this: Record<string, unknown>) {
      this.getStats = vi.fn().mockResolvedValue({
        totalCostUsd: 1.25,
        totalInputTokens: 100,
        totalOutputTokens: 50,
        entryCount: 2,
        byTier: {},
        byModel: {},
      });
      this.getResolutionRate = vi.fn().mockResolvedValue({ total: 0, successes: 0, rate: 0 });
    });
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    await runCommand(["--stats", "all", "--json"]);

    const parsed = JSON.parse(String(logSpy.mock.calls[0]?.[0] ?? "{}"));
    expect(parsed).toMatchObject({
      totalCostUsd: 1.25,
      totalInputTokens: 100,
      totalOutputTokens: 50,
      entryCount: 2,
    });
  });
});
