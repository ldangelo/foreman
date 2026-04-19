/**
 * Tests for src/orchestrator/auto-merge.ts
 *
 * Verifies:
 * - autoMerge() returns {merged:0,conflicts:0,failed:0} when no project is registered
 * - autoMerge() reconciles and drains the queue when a project exists
 * - autoMerge() counts merged/conflict/failed outcomes correctly
 * - autoMerge() handles per-entry refinery errors gracefully (non-fatal)
 * - autoMerge() syncs bead status after each merge outcome
 * - syncBeadStatusAfterMerge() is non-fatal when br or taskClient fails
 *
 * These tests mirror the existing run-auto-merge.test.ts unit tests but
 * exercise the module directly (now that the logic is in auto-merge.ts).
 */

import { describe, it, expect, vi, beforeEach } from "vitest";

// ── Hoisted mocks ────────────────────────────────────────────────────────────

const {
  mockExecFileSync,
  mockGetProjectByPath,
  mockGetDb,
  mockGetRun,
  MockForemanStore,
  mockMergeQueueReconcile,
  mockMergeQueueDequeue,
  mockMergeQueueUpdateStatus,
  MockMergeQueue,
  mockRefineryMergeCompleted,
  MockRefinery,
  mockDetectDefaultBranch,
  mockCreateVcsBackend,
  mockTaskClientUpdate,
  mockAddNotesToBead,
  mockMarkBeadFailed,
  mockSetBeadStatus,
  mockGetRunsByStatuses,
} = vi.hoisted(() => {
  const mockExecFileSync = vi.fn().mockReturnValue(Buffer.from(""));

  const mockGetProjectByPath = vi.fn().mockReturnValue(null);
  const mockGetDb = vi.fn().mockReturnValue({});
  const mockGetRun = vi.fn().mockReturnValue(null);
  const MockForemanStore = vi.fn(function (this: Record<string, unknown>) {
    this.close = vi.fn();
    this.getProjectByPath = mockGetProjectByPath;
    this.getDb = mockGetDb;
    this.getRun = mockGetRun;
  });
  (MockForemanStore as unknown as { forProject: ReturnType<typeof vi.fn> }).forProject =
    vi.fn((...args: unknown[]) => new (MockForemanStore as unknown as new (...a: unknown[]) => unknown)(...args));

  const mockMergeQueueReconcile = vi.fn().mockResolvedValue({ enqueued: 0, skipped: 0, invalidBranch: 0 });
  const mockMergeQueueDequeue = vi.fn().mockReturnValue(null);
  const mockAddNotesToBead = vi.fn();
  const mockSetBeadStatus = vi.fn();
  const mockMergeQueueUpdateStatus = vi.fn();
  const MockMergeQueue = vi.fn(function (this: Record<string, unknown>) {
    this.reconcile = mockMergeQueueReconcile;
    this.dequeue = mockMergeQueueDequeue;
    this.updateStatus = mockMergeQueueUpdateStatus;
  });

  const mockRefineryMergeCompleted = vi.fn().mockResolvedValue({
    merged: [],
    conflicts: [],
    testFailures: [],
    unexpectedErrors: [],
    prsCreated: [],
  });
  const MockRefinery = vi.fn(function (this: Record<string, unknown>) {
    this.mergeCompleted = mockRefineryMergeCompleted;
  });

  const mockDetectDefaultBranch = vi.fn().mockResolvedValue("main");
  const mockCreateVcsBackend = vi.fn().mockResolvedValue({
    name: "git",
    detectDefaultBranch: mockDetectDefaultBranch,
  });
  const mockTaskClientUpdate = vi.fn().mockResolvedValue(undefined);
  const mockMarkBeadFailed = vi.fn().mockResolvedValue(undefined);
  const mockGetRunsByStatuses = vi.fn().mockReturnValue([]);

  return {
    mockExecFileSync,
    mockGetProjectByPath,
    mockGetDb,
    mockGetRun,
    MockForemanStore,
    mockMergeQueueReconcile,
    mockMergeQueueDequeue,
    mockMergeQueueUpdateStatus,
    MockMergeQueue,
    mockRefineryMergeCompleted,
    MockRefinery,
    mockDetectDefaultBranch,
    mockCreateVcsBackend,
    mockTaskClientUpdate,
    mockAddNotesToBead,
    mockMarkBeadFailed,
    mockSetBeadStatus,
    mockGetRunsByStatuses,
  };
});

vi.mock("node:child_process", () => ({
  execFile: vi.fn(),
  execFileSync: mockExecFileSync,
}));

vi.mock("../../lib/store.js", () => ({ ForemanStore: MockForemanStore }));
vi.mock("../merge-queue.js", () => ({
  MergeQueue: MockMergeQueue,
  RETRY_CONFIG: { maxRetries: 3, initialDelayMs: 60_000, maxDelayMs: 3_600_000, backoffMultiplier: 2 },
}));
vi.mock("../refinery.js", () => ({ Refinery: MockRefinery }));
vi.mock("../../lib/project-config.js", () => ({
  loadProjectConfig: vi.fn().mockReturnValue(null),
  resolveVcsConfig: vi.fn().mockReturnValue({ backend: "auto" }),
}));
vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: mockCreateVcsBackend,
  },
}));
vi.mock("../task-backend-ops.js", () => ({
  enqueueAddNotesToBead: mockAddNotesToBead,
  enqueueMarkBeadFailed: mockMarkBeadFailed,
  enqueueSetBeadStatus: mockSetBeadStatus,
}));

import { autoMerge, syncBeadStatusAfterMerge, type AutoMergeOpts } from "../auto-merge.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeStore(overrides: Partial<{
  getProjectByPath: ReturnType<typeof vi.fn>;
  getDb: ReturnType<typeof vi.fn>;
  getRun: ReturnType<typeof vi.fn>;
  getRunsByStatuses: ReturnType<typeof vi.fn>;
}> = {}): ReturnType<typeof vi.fn> {
  return {
    close: vi.fn(),
    getProjectByPath: overrides.getProjectByPath ?? mockGetProjectByPath,
    getDb: overrides.getDb ?? mockGetDb,
    getRun: overrides.getRun ?? mockGetRun,
    getRunsByStatuses: overrides.getRunsByStatuses ?? mockGetRunsByStatuses,
    sendMessage: vi.fn(),
  } as unknown as ReturnType<typeof vi.fn>;
}

function makeTaskClient(overrides: Partial<{
  update: ReturnType<typeof vi.fn>;
}> = {}): { update: ReturnType<typeof vi.fn> } {
  return { update: overrides.update ?? mockTaskClientUpdate };
}

function makeOpts(
  overrides: Partial<AutoMergeOpts> = {},
): AutoMergeOpts {
  return {
    store: makeStore() as never,
    taskClient: makeTaskClient() as never,
    projectPath: "/mock/project",
    ...overrides,
  };
}

function resetMocks(): void {
  vi.clearAllMocks();
  vi.spyOn(console, "warn").mockImplementation(() => {});

  mockExecFileSync.mockReturnValue(Buffer.from(""));
  mockDetectDefaultBranch.mockResolvedValue("main");
  mockCreateVcsBackend.mockResolvedValue({
    name: "git",
    detectDefaultBranch: mockDetectDefaultBranch,
  });
  mockGetProjectByPath.mockReturnValue(null);
  mockGetDb.mockReturnValue({});
  mockGetRun.mockReturnValue(null);
  mockMergeQueueReconcile.mockResolvedValue({ enqueued: 0, skipped: 0, invalidBranch: 0 });
  mockMergeQueueDequeue.mockReturnValue(null);
  mockMergeQueueUpdateStatus.mockReturnValue(undefined);
  mockRefineryMergeCompleted.mockResolvedValue({
    merged: [],
    conflicts: [],
    testFailures: [],
    unexpectedErrors: [],
    prsCreated: [],
  });
  mockTaskClientUpdate.mockResolvedValue(undefined);
  mockAddNotesToBead.mockReturnValue(undefined);
  mockMarkBeadFailed.mockResolvedValue(undefined);
  mockGetRunsByStatuses.mockReturnValue([]);
}

// ── autoMerge() — no project registered ─────────────────────────────────────

describe("autoMerge() — no project registered", () => {
  beforeEach(resetMocks);

  it("returns {merged:0,conflicts:0,failed:0} when getProjectByPath returns null", async () => {
    const store = makeStore({ getProjectByPath: vi.fn().mockReturnValue(null) });
    const result = await autoMerge({
      store: store as never,
      taskClient: makeTaskClient() as never,
      projectPath: "/mock/project",
    } satisfies AutoMergeOpts);

    expect(result).toEqual({ merged: 0, conflicts: 0, failed: 0 });
  });

  it("does not call MergeQueue or Refinery when no project", async () => {
    const store = makeStore({ getProjectByPath: vi.fn().mockReturnValue(null) });
    await autoMerge({ store: store as never, taskClient: makeTaskClient() as never, projectPath: "/x" });

    expect(MockMergeQueue).not.toHaveBeenCalled();
    expect(MockRefinery).not.toHaveBeenCalled();
  });
});

// ── autoMerge() — project registered, empty queue ───────────────────────────

describe("autoMerge() — project registered, empty queue", () => {
  beforeEach(() => {
    resetMocks();
    mockGetProjectByPath.mockReturnValue({ id: "proj-1", path: "/mock/project" });
    mockMergeQueueDequeue.mockReturnValue(null);
  });

  it("returns {merged:0,conflicts:0,failed:0} when queue is empty", async () => {
    const result = await autoMerge(makeOpts({
      store: makeStore({ getProjectByPath: mockGetProjectByPath }) as never,
    }));
    expect(result).toEqual({ merged: 0, conflicts: 0, failed: 0 });
  });

  it("calls reconcile before dequeue", async () => {
    const callOrder: string[] = [];
    mockMergeQueueReconcile.mockImplementation(() => { callOrder.push("reconcile"); return Promise.resolve({}); });
    mockMergeQueueDequeue.mockImplementation(() => { callOrder.push("dequeue"); return null; });

    await autoMerge(makeOpts({
      store: makeStore({ getProjectByPath: vi.fn().mockReturnValue({ id: "p" }) }) as never,
    }));

    expect(callOrder).toEqual(["reconcile", "dequeue"]);
  });

  it("uses detected default branch when targetBranch not provided", async () => {
    mockDetectDefaultBranch.mockResolvedValue("trunk");
    mockGetProjectByPath.mockReturnValue({ id: "p" });

    await autoMerge(makeOpts({
      store: makeStore({ getProjectByPath: mockGetProjectByPath }) as never,
    }));

    expect(mockDetectDefaultBranch).toHaveBeenCalledWith("/mock/project");
  });

  it("uses provided targetBranch without calling detectDefaultBranch", async () => {
    mockGetProjectByPath.mockReturnValue({ id: "p" });

    await autoMerge(makeOpts({
      store: makeStore({ getProjectByPath: mockGetProjectByPath }) as never,
      targetBranch: "main",
    }));

    expect(mockDetectDefaultBranch).not.toHaveBeenCalled();
  });
});

// ── autoMerge() — merge outcomes ────────────────────────────────────────────

describe("autoMerge() — merge outcomes", () => {
  beforeEach(() => {
    resetMocks();
    mockGetProjectByPath.mockReturnValue({ id: "proj-1" });
  });

  function makeEntry(id: number = 1) {
    return { id, seed_id: `bd-test-00${id}`, run_id: `run-00${id}` };
  }

  it("increments mergedCount when report.merged is non-empty", async () => {
    mockMergeQueueDequeue.mockReturnValueOnce(makeEntry()).mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValueOnce({
      merged: [{ seedId: "bd-test-001" }],
      conflicts: [],
      testFailures: [],
      unexpectedErrors: [],
      prsCreated: [],
    });

    const result = await autoMerge(makeOpts({
      store: makeStore({ getProjectByPath: mockGetProjectByPath }) as never,
    }));

    expect(result.merged).toBe(1);
    expect(result.conflicts).toBe(0);
    expect(result.failed).toBe(0);
    expect(mockMergeQueueUpdateStatus).toHaveBeenCalledWith(1, "merged", expect.any(Object));
  });

  it("increments conflictCount when report.conflicts is non-empty", async () => {
    mockMergeQueueDequeue.mockReturnValueOnce(makeEntry()).mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValueOnce({
      merged: [],
      conflicts: [{ seedId: "bd-test-001" }],
      testFailures: [],
      unexpectedErrors: [],
      prsCreated: [],
    });

    const result = await autoMerge(makeOpts({
      store: makeStore({ getProjectByPath: mockGetProjectByPath }) as never,
    }));

    expect(result.conflicts).toBe(1);
    expect(mockMergeQueueUpdateStatus).toHaveBeenCalledWith(1, "conflict", expect.any(Object));
  });

  it("increments conflictCount for prsCreated entries", async () => {
    mockMergeQueueDequeue.mockReturnValueOnce(makeEntry()).mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValueOnce({
      merged: [],
      conflicts: [],
      testFailures: [],
      unexpectedErrors: [],
      prsCreated: [{ seedId: "bd-test-001", url: "https://github.com/x/y/pull/1" }],
    });

    const result = await autoMerge(makeOpts({
      store: makeStore({ getProjectByPath: mockGetProjectByPath }) as never,
    }));

    expect(result.conflicts).toBe(1);
    expect(mockMergeQueueUpdateStatus).toHaveBeenCalledWith(1, "conflict", expect.any(Object));
  });

  it("increments failedCount when report.testFailures is non-empty", async () => {
    mockMergeQueueDequeue.mockReturnValueOnce(makeEntry()).mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValueOnce({
      merged: [],
      conflicts: [],
      testFailures: [{ seedId: "bd-test-001" }],
      unexpectedErrors: [],
      prsCreated: [],
    });

    const result = await autoMerge(makeOpts({
      store: makeStore({ getProjectByPath: mockGetProjectByPath }) as never,
    }));

    expect(result.failed).toBe(1);
    expect(mockMergeQueueUpdateStatus).toHaveBeenCalledWith(1, "failed", expect.any(Object));
  });

  it("increments failedCount and marks 'failed' when all report arrays are empty", async () => {
    mockMergeQueueDequeue.mockReturnValueOnce(makeEntry()).mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValueOnce({
      merged: [],
      conflicts: [],
      testFailures: [],
      unexpectedErrors: [],
      prsCreated: [],
    });

    const result = await autoMerge(makeOpts({
      store: makeStore({ getProjectByPath: mockGetProjectByPath }) as never,
    }));

    expect(result.failed).toBe(1);
    expect(mockMergeQueueUpdateStatus).toHaveBeenCalledWith(1, "failed", { error: "No completed run found" });
  });

  // ── autoMerge() — race condition fix (overrideRun) ──────────────────────────

  describe("autoMerge() — race condition fix (runId)", () => {
    beforeEach(() => {
      resetMocks();
      mockGetProjectByPath.mockReturnValue({ id: "proj-1" });
    });

    it("passes runId to mergeCompleted to fetch by ID (no status filter)", async () => {
      const entry = makeEntry(1);
      const mockRun = { id: entry.run_id, seed_id: entry.seed_id, status: "completed" };
      mockMergeQueueDequeue.mockReturnValueOnce(entry).mockReturnValue(null);
      mockGetRun.mockReturnValueOnce(mockRun);
      mockRefineryMergeCompleted.mockResolvedValueOnce({
        merged: [{ seedId: "bd-test-001" }],
        conflicts: [],
        testFailures: [],
        unexpectedErrors: [],
        prsCreated: [],
      });

      await autoMerge(makeOpts({
        store: makeStore({ getProjectByPath: mockGetProjectByPath }) as never,
      }));

      // Verify runId was passed to mergeCompleted to fetch by ID directly.
      // This is the most reliable approach because:
      // 1. It bypasses status filtering entirely
      // 2. Eliminates the race condition where status update hasn't been
      //    committed/visible when the query runs
      expect(mockRefineryMergeCompleted).toHaveBeenCalledWith(
        expect.objectContaining({ runId: entry.run_id })
      );
    });
  });

  it("handles multiple queue entries correctly", async () => {
    mockMergeQueueDequeue
      .mockReturnValueOnce(makeEntry(1))
      .mockReturnValueOnce(makeEntry(2))
      .mockReturnValueOnce(makeEntry(3))
      .mockReturnValue(null);
    mockRefineryMergeCompleted
      .mockResolvedValueOnce({ merged: [{}], conflicts: [], testFailures: [], unexpectedErrors: [], prsCreated: [] })
      .mockResolvedValueOnce({ merged: [], conflicts: [{}], testFailures: [], unexpectedErrors: [], prsCreated: [] })
      .mockResolvedValueOnce({ merged: [], conflicts: [], testFailures: [{}], unexpectedErrors: [], prsCreated: [] });

    const result = await autoMerge(makeOpts({
      store: makeStore({ getProjectByPath: mockGetProjectByPath }) as never,
    }));

    expect(result).toEqual({ merged: 1, conflicts: 1, failed: 1 });
  });
});

// ── autoMerge() — error handling ────────────────────────────────────────────

describe("autoMerge() — refinery errors are non-fatal", () => {
  beforeEach(() => {
    resetMocks();
    mockGetProjectByPath.mockReturnValue({ id: "proj-1" });
  });

  it("catches refinery.mergeCompleted() throw and increments failedCount", async () => {
    mockMergeQueueDequeue
      .mockReturnValueOnce({ id: 1, seed_id: "bd-x", run_id: "run-x" })
      .mockReturnValue(null);
    mockRefineryMergeCompleted.mockRejectedValueOnce(new Error("git rebase failed"));

    const result = await autoMerge(makeOpts({
      store: makeStore({ getProjectByPath: mockGetProjectByPath }) as never,
    }));

    expect(result.failed).toBe(1);
    expect(mockMergeQueueUpdateStatus).toHaveBeenCalledWith(1, "failed", { error: "git rebase failed" });
  });

  it("does not throw to caller when refinery throws", async () => {
    mockMergeQueueDequeue
      .mockReturnValueOnce({ id: 1, seed_id: "bd-x", run_id: "run-x" })
      .mockReturnValue(null);
    mockRefineryMergeCompleted.mockRejectedValue(new Error("boom"));

    await expect(autoMerge(makeOpts({
      store: makeStore({ getProjectByPath: mockGetProjectByPath }) as never,
    }))).resolves.not.toThrow();
  });

  it("continues processing subsequent queue entries after a refinery error", async () => {
    mockMergeQueueDequeue
      .mockReturnValueOnce({ id: 1, seed_id: "bd-1", run_id: "run-1" })
      .mockReturnValueOnce({ id: 2, seed_id: "bd-2", run_id: "run-2" })
      .mockReturnValue(null);
    mockRefineryMergeCompleted
      .mockRejectedValueOnce(new Error("first entry fails"))
      .mockResolvedValueOnce({ merged: [{}], conflicts: [], testFailures: [], unexpectedErrors: [], prsCreated: [] });

    const result = await autoMerge(makeOpts({
      store: makeStore({ getProjectByPath: mockGetProjectByPath }) as never,
    }));

    // First failed, second merged
    expect(result.failed).toBe(1);
    expect(result.merged).toBe(1);
  });
});

// ── syncBeadStatusAfterMerge() ────────────────────────────────────────────────

describe("syncBeadStatusAfterMerge()", () => {
  beforeEach(resetMocks);

  it("does nothing when run is not found in store", async () => {
    const store = makeStore({ getRun: vi.fn().mockReturnValue(null) });
    const taskClient = makeTaskClient();

    await syncBeadStatusAfterMerge(store as never, taskClient as never, "run-x", "bd-x", "/proj");

    expect(mockSetBeadStatus).not.toHaveBeenCalled();
  });

  it("enqueues status update instead of calling br directly", async () => {
    const store = makeStore({
      getRun: vi.fn().mockReturnValue({ id: "run-1", status: "merged" }),
    });
    const taskClient = makeTaskClient();

    await syncBeadStatusAfterMerge(store as never, taskClient as never, "run-1", "bd-x", "/proj");

    expect(mockSetBeadStatus).toHaveBeenCalledWith(
      expect.anything(), "bd-x", "closed", "auto-merge",
    );
    // Should NOT call taskClient.update directly (avoids SQLITE_BUSY)
    expect(taskClient.update).not.toHaveBeenCalled();
  });

  it("calls addNotesToBead with the failure reason when failureReason is provided", async () => {
    const store = makeStore({
      getRun: vi.fn().mockReturnValue({ id: "run-1", status: "conflict" }),
    });
    const taskClient = makeTaskClient({ update: vi.fn().mockResolvedValue(undefined) });

    await syncBeadStatusAfterMerge(
      store as never,
      taskClient as never,
      "run-1",
      "bd-test-001",
      "/proj",
      "Merge conflict detected in branch foreman/bd-test-001.\nConflicting files:\n  - src/foo.ts",
    );

    expect(mockAddNotesToBead).toHaveBeenCalledWith(
      expect.anything(),
      "bd-test-001",
      "Merge conflict detected in branch foreman/bd-test-001.\nConflicting files:\n  - src/foo.ts",
      "auto-merge",
    );
  });

  it("does NOT call addNotesToBead when failureReason is not provided", async () => {
    const store = makeStore({
      getRun: vi.fn().mockReturnValue({ id: "run-1", status: "merged" }),
    });
    const taskClient = makeTaskClient({ update: vi.fn().mockResolvedValue(undefined) });

    await syncBeadStatusAfterMerge(
      store as never,
      taskClient as never,
      "run-1",
      "bd-test-001",
      "/proj",
      // no failureReason
    );

    expect(mockAddNotesToBead).not.toHaveBeenCalled();
  });

  it("maps conflict run status to blocked", async () => {
    const store = makeStore({
      getRun: vi.fn().mockReturnValue({ id: "run-1", status: "conflict" }),
    });
    const taskClient = makeTaskClient();

    await syncBeadStatusAfterMerge(store as never, taskClient as never, "run-1", "bd-x", "/proj");

    expect(mockSetBeadStatus).toHaveBeenCalledWith(expect.anything(), "bd-x", "blocked", "auto-merge");
  });

  it("maps test-failed run status to blocked", async () => {
    const store = makeStore({
      getRun: vi.fn().mockReturnValue({ id: "run-1", status: "test-failed" }),
    });
    const taskClient = makeTaskClient();

    await syncBeadStatusAfterMerge(store as never, taskClient as never, "run-1", "bd-x", "/proj");

    expect(mockSetBeadStatus).toHaveBeenCalledWith(expect.anything(), "bd-x", "blocked", "auto-merge");
  });

  it("maps failed run status to failed", async () => {
    const store = makeStore({
      getRun: vi.fn().mockReturnValue({ id: "run-1", status: "failed" }),
    });
    const taskClient = makeTaskClient();

    await syncBeadStatusAfterMerge(store as never, taskClient as never, "run-1", "bd-x", "/proj");

    expect(mockSetBeadStatus).toHaveBeenCalledWith(expect.anything(), "bd-x", "failed", "auto-merge");
  });

  it("always enqueues notes even when called with a failure reason", async () => {
    const store = makeStore({
      getRun: vi.fn().mockReturnValue({ id: "run-1", status: "conflict" }),
    });
    const taskClient = makeTaskClient();

    await syncBeadStatusAfterMerge(
      store as never,
      taskClient as never,
      "run-1",
      "bd-x",
      "/proj",
      "Merge conflict in foo.ts",
    );

    // Both status and notes should be enqueued
    expect(mockSetBeadStatus).toHaveBeenCalled();
    expect(mockAddNotesToBead).toHaveBeenCalledWith(expect.anything(), "bd-x", "Merge conflict in foo.ts", "auto-merge");
  });
});

// ── autoMerge() — bead failure notes ────────────────────────────────────────

describe("autoMerge() — bead failure notes via addNotesToBead", () => {
  beforeEach(() => {
    resetMocks();
    mockGetProjectByPath.mockReturnValue({ id: "proj-1" });
    mockGetRun.mockReturnValue({ id: "run-001", status: "conflict" });
  });

  function makeEntry(id: number = 1) {
    return { id, seed_id: `bd-test-00${id}`, run_id: `run-00${id}`, branch_name: `foreman/bd-test-00${id}` };
  }

  it("calls addNotesToBead with conflict files when merge conflict occurs", async () => {
    mockMergeQueueDequeue.mockReturnValueOnce(makeEntry()).mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValueOnce({
      merged: [],
      conflicts: [{ runId: "run-001", seedId: "bd-test-001", branchName: "foreman/bd-test-001", conflictFiles: ["src/foo.ts", "src/bar.ts"] }],
      testFailures: [],
      unexpectedErrors: [],
      prsCreated: [],
    });

    await autoMerge(makeOpts({
      store: makeStore({ getProjectByPath: mockGetProjectByPath, getRun: vi.fn().mockReturnValue({ id: "run-001", status: "conflict" }) }) as never,
    }));

    expect(mockAddNotesToBead).toHaveBeenCalledWith(
      expect.anything(),
      "bd-test-001",
      expect.stringContaining("src/foo.ts"),
      "auto-merge",
    );
  });

  it("calls addNotesToBead with PR URL when PR was created on conflict", async () => {
    mockMergeQueueDequeue.mockReturnValueOnce(makeEntry()).mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValueOnce({
      merged: [],
      conflicts: [],
      testFailures: [],
      unexpectedErrors: [],
      prsCreated: [{ runId: "run-001", seedId: "bd-test-001", branchName: "foreman/bd-test-001", prUrl: "https://github.com/x/y/pull/42" }],
    });

    await autoMerge(makeOpts({
      store: makeStore({ getProjectByPath: mockGetProjectByPath, getRun: vi.fn().mockReturnValue({ id: "run-001", status: "pr-created" }) }) as never,
    }));

    expect(mockAddNotesToBead).toHaveBeenCalledWith(
      expect.anything(),
      "bd-test-001",
      expect.stringContaining("https://github.com/x/y/pull/42"),
      "auto-merge",
    );
  });

  it("calls addNotesToBead with test failure summary when post-merge tests fail", async () => {
    mockMergeQueueDequeue.mockReturnValueOnce(makeEntry()).mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValueOnce({
      merged: [],
      conflicts: [],
      testFailures: [{ runId: "run-001", seedId: "bd-test-001", branchName: "foreman/bd-test-001", error: "FAIL src/foo.test.ts\n  ✕ should work (50ms)" }],
      unexpectedErrors: [],
      prsCreated: [],
    });

    await autoMerge(makeOpts({
      store: makeStore({ getProjectByPath: mockGetProjectByPath, getRun: vi.fn().mockReturnValue({ id: "run-001", status: "test-failed" }) }) as never,
    }));

    expect(mockAddNotesToBead).toHaveBeenCalledWith(
      expect.anything(),
      "bd-test-001",
      expect.stringContaining("FAIL src/foo.test.ts"),
      "auto-merge",
    );
  });

  it("calls addNotesToBead with exception message when refinery throws", async () => {
    mockMergeQueueDequeue
      .mockReturnValueOnce({ id: 1, seed_id: "bd-err-001", run_id: "run-001", branch_name: "foreman/bd-err-001" })
      .mockReturnValue(null);
    mockRefineryMergeCompleted.mockRejectedValueOnce(new Error("git rebase failed: conflict in HEAD"));
    mockGetRun.mockReturnValue({ id: "run-001", status: "failed" });

    await autoMerge(makeOpts({
      store: makeStore({ getProjectByPath: mockGetProjectByPath, getRun: vi.fn().mockReturnValue({ id: "run-001", status: "failed" }) }) as never,
    }));

    expect(mockAddNotesToBead).toHaveBeenCalledWith(
      expect.anything(),
      "bd-err-001",
      expect.stringContaining("git rebase failed: conflict in HEAD"),
      "auto-merge",
    );
  });

  it("does NOT call addNotesToBead when merge succeeds", async () => {
    mockMergeQueueDequeue.mockReturnValueOnce(makeEntry()).mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValueOnce({
      merged: [{ runId: "run-001", seedId: "bd-test-001", branchName: "foreman/bd-test-001" }],
      conflicts: [],
      testFailures: [],
      unexpectedErrors: [],
      prsCreated: [],
    });

    await autoMerge(makeOpts({
      store: makeStore({ getProjectByPath: mockGetProjectByPath, getRun: vi.fn().mockReturnValue({ id: "run-001", status: "merged" }) }) as never,
    }));

    expect(mockAddNotesToBead).not.toHaveBeenCalled();
  });
});

// ── autoMerge() — test failure retry exhaustion ──────────────────────────────

describe("autoMerge() — test failure retry exhaustion (infinite loop prevention)", () => {
  beforeEach(() => {
    resetMocks();
    mockGetProjectByPath.mockReturnValue({ id: "proj-1" });
  });

  function makeEntry(id: number = 1) {
    return { id, seed_id: `bd-test-00${id}`, run_id: `run-00${id}`, branch_name: `foreman/bd-test-00${id}` };
  }

  it("does NOT call markBeadFailed when test-failed count is below the retry limit", async () => {
    // Only 1 test-failed run (first attempt) — under the limit of 3
    mockGetRunsByStatuses.mockReturnValue([
      { seed_id: "bd-test-001", status: "test-failed" },
    ]);
    mockMergeQueueDequeue.mockReturnValueOnce(makeEntry()).mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValueOnce({
      merged: [],
      conflicts: [],
      testFailures: [{ runId: "run-001", seedId: "bd-test-001", branchName: "foreman/bd-test-001", error: "FAIL test.ts" }],
      unexpectedErrors: [],
      prsCreated: [],
    });

    await autoMerge(makeOpts({
      store: makeStore({
        getProjectByPath: mockGetProjectByPath,
        getRun: vi.fn().mockReturnValue({ id: "run-001", status: "test-failed" }),
      }) as never,
    }));

    // Should NOT permanently fail the bead yet
    expect(mockMarkBeadFailed).not.toHaveBeenCalled();
  });

  it("calls markBeadFailed when test-failed count reaches RETRY_CONFIG.maxRetries (3)", async () => {
    // 3 test-failed runs for this seed — at the retry limit
    mockGetRunsByStatuses.mockReturnValue([
      { seed_id: "bd-test-001", status: "test-failed" },
      { seed_id: "bd-test-001", status: "test-failed" },
      { seed_id: "bd-test-001", status: "test-failed" },
    ]);
    mockMergeQueueDequeue.mockReturnValueOnce(makeEntry()).mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValueOnce({
      merged: [],
      conflicts: [],
      testFailures: [{ runId: "run-001", seedId: "bd-test-001", branchName: "foreman/bd-test-001", error: "FAIL test.ts" }],
      unexpectedErrors: [],
      prsCreated: [],
    });

    await autoMerge(makeOpts({
      store: makeStore({
        getProjectByPath: mockGetProjectByPath,
        getRun: vi.fn().mockReturnValue({ id: "run-001", status: "test-failed" }),
      }) as never,
    }));

    // Should permanently fail the bead to break the infinite loop
    expect(mockMarkBeadFailed).toHaveBeenCalledWith(expect.anything(), "bd-test-001", "auto-merge");
  });

  it("calls markBeadFailed when test-failed count exceeds RETRY_CONFIG.maxRetries", async () => {
    // 5 test-failed runs — well over the limit
    mockGetRunsByStatuses.mockReturnValue([
      { seed_id: "bd-test-001", status: "test-failed" },
      { seed_id: "bd-test-001", status: "test-failed" },
      { seed_id: "bd-test-001", status: "test-failed" },
      { seed_id: "bd-test-001", status: "test-failed" },
      { seed_id: "bd-test-001", status: "test-failed" },
    ]);
    mockMergeQueueDequeue.mockReturnValueOnce(makeEntry()).mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValueOnce({
      merged: [],
      conflicts: [],
      testFailures: [{ runId: "run-001", seedId: "bd-test-001", branchName: "foreman/bd-test-001", error: "Tests failed" }],
      unexpectedErrors: [],
      prsCreated: [],
    });

    await autoMerge(makeOpts({
      store: makeStore({
        getProjectByPath: mockGetProjectByPath,
        getRun: vi.fn().mockReturnValue({ id: "run-001", status: "test-failed" }),
      }) as never,
    }));

    expect(mockMarkBeadFailed).toHaveBeenCalledWith(expect.anything(), "bd-test-001", "auto-merge");
  });

  it("only counts test-failed runs for the specific seed — not other seeds", async () => {
    // 3 test-failed runs but for a different seed — should not trigger retry exhaustion
    mockGetRunsByStatuses.mockReturnValue([
      { seed_id: "bd-other-001", status: "test-failed" },
      { seed_id: "bd-other-001", status: "test-failed" },
      { seed_id: "bd-other-001", status: "test-failed" },
    ]);
    mockMergeQueueDequeue.mockReturnValueOnce(makeEntry()).mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValueOnce({
      merged: [],
      conflicts: [],
      testFailures: [{ runId: "run-001", seedId: "bd-test-001", branchName: "foreman/bd-test-001", error: "FAIL test.ts" }],
      unexpectedErrors: [],
      prsCreated: [],
    });

    await autoMerge(makeOpts({
      store: makeStore({
        getProjectByPath: mockGetProjectByPath,
        getRun: vi.fn().mockReturnValue({ id: "run-001", status: "test-failed" }),
      }) as never,
    }));

    // Other seed's failures should not affect this seed
    expect(mockMarkBeadFailed).not.toHaveBeenCalled();
  });

  it("includes retry exhaustion context in the failure message when limit is reached", async () => {
    mockGetRunsByStatuses.mockReturnValue([
      { seed_id: "bd-test-001", status: "test-failed" },
      { seed_id: "bd-test-001", status: "test-failed" },
      { seed_id: "bd-test-001", status: "test-failed" },
    ]);
    mockMergeQueueDequeue.mockReturnValueOnce(makeEntry()).mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValueOnce({
      merged: [],
      conflicts: [],
      testFailures: [{ runId: "run-001", seedId: "bd-test-001", branchName: "foreman/bd-test-001", error: "FAIL test.ts" }],
      unexpectedErrors: [],
      prsCreated: [],
    });

    await autoMerge(makeOpts({
      store: makeStore({
        getProjectByPath: mockGetProjectByPath,
        getRun: vi.fn().mockReturnValue({ id: "run-001", status: "test-failed" }),
      }) as never,
    }));

    // The failure note should mention exhaustion and manual intervention
    expect(mockAddNotesToBead).toHaveBeenCalledWith(
      expect.anything(),
      "bd-test-001",
      expect.stringContaining("exhausted"),
      "auto-merge",
    );
  });

  it("includes attempt count in the failure message when under retry limit", async () => {
    mockGetRunsByStatuses.mockReturnValue([
      { seed_id: "bd-test-001", status: "test-failed" },
    ]);
    mockMergeQueueDequeue.mockReturnValueOnce(makeEntry()).mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValueOnce({
      merged: [],
      conflicts: [],
      testFailures: [{ runId: "run-001", seedId: "bd-test-001", branchName: "foreman/bd-test-001", error: "FAIL test.ts" }],
      unexpectedErrors: [],
      prsCreated: [],
    });

    await autoMerge(makeOpts({
      store: makeStore({
        getProjectByPath: mockGetProjectByPath,
        getRun: vi.fn().mockReturnValue({ id: "run-001", status: "test-failed" }),
      }) as never,
    }));

    // The failure note should mention the attempt number
    expect(mockAddNotesToBead).toHaveBeenCalledWith(
      expect.anything(),
      "bd-test-001",
      expect.stringContaining("attempt"),
      "auto-merge",
    );
  });

  it("still marks the MQ entry as failed regardless of retry exhaustion", async () => {
    // At retry limit
    mockGetRunsByStatuses.mockReturnValue([
      { seed_id: "bd-test-001", status: "test-failed" },
      { seed_id: "bd-test-001", status: "test-failed" },
      { seed_id: "bd-test-001", status: "test-failed" },
    ]);
    mockMergeQueueDequeue.mockReturnValueOnce(makeEntry()).mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValueOnce({
      merged: [],
      conflicts: [],
      testFailures: [{ runId: "run-001", seedId: "bd-test-001", branchName: "foreman/bd-test-001", error: "Tests failed" }],
      unexpectedErrors: [],
      prsCreated: [],
    });

    await autoMerge(makeOpts({
      store: makeStore({
        getProjectByPath: mockGetProjectByPath,
        getRun: vi.fn().mockReturnValue({ id: "run-001", status: "test-failed" }),
      }) as never,
    }));

    expect(mockMergeQueueUpdateStatus).toHaveBeenCalledWith(1, "failed", { error: "Test failures" });
  });
});
