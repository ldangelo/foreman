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
  mockTaskClientUpdate,
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
    prsCreated: [],
  });
  const MockRefinery = vi.fn(function (this: Record<string, unknown>) {
    this.mergeCompleted = mockRefineryMergeCompleted;
  });

  const mockDetectDefaultBranch = vi.fn().mockResolvedValue("main");
  const mockTaskClientUpdate = vi.fn().mockResolvedValue(undefined);

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
    mockTaskClientUpdate,
  };
});

vi.mock("node:child_process", () => ({
  execFile: vi.fn(),
  execFileSync: mockExecFileSync,
}));

vi.mock("../../lib/store.js", () => ({ ForemanStore: MockForemanStore }));
vi.mock("../merge-queue.js", () => ({ MergeQueue: MockMergeQueue }));
vi.mock("../refinery.js", () => ({ Refinery: MockRefinery }));
vi.mock("../../lib/git.js", () => ({
  detectDefaultBranch: mockDetectDefaultBranch,
}));

import { autoMerge, syncBeadStatusAfterMerge, type AutoMergeOpts } from "../auto-merge.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeStore(overrides: Partial<{
  getProjectByPath: ReturnType<typeof vi.fn>;
  getDb: ReturnType<typeof vi.fn>;
  getRun: ReturnType<typeof vi.fn>;
}> = {}): ReturnType<typeof vi.fn> {
  return {
    close: vi.fn(),
    getProjectByPath: overrides.getProjectByPath ?? mockGetProjectByPath,
    getDb: overrides.getDb ?? mockGetDb,
    getRun: overrides.getRun ?? mockGetRun,
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
    prsCreated: [],
  });
  mockTaskClientUpdate.mockResolvedValue(undefined);
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
      prsCreated: [],
    });

    const result = await autoMerge(makeOpts({
      store: makeStore({ getProjectByPath: mockGetProjectByPath }) as never,
    }));

    expect(result.failed).toBe(1);
    expect(mockMergeQueueUpdateStatus).toHaveBeenCalledWith(1, "failed", { error: "No completed run found" });
  });

  it("handles multiple queue entries correctly", async () => {
    mockMergeQueueDequeue
      .mockReturnValueOnce(makeEntry(1))
      .mockReturnValueOnce(makeEntry(2))
      .mockReturnValueOnce(makeEntry(3))
      .mockReturnValue(null);
    mockRefineryMergeCompleted
      .mockResolvedValueOnce({ merged: [{}], conflicts: [], testFailures: [], prsCreated: [] })
      .mockResolvedValueOnce({ merged: [], conflicts: [{}], testFailures: [], prsCreated: [] })
      .mockResolvedValueOnce({ merged: [], conflicts: [], testFailures: [{}], prsCreated: [] });

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
      .mockResolvedValueOnce({ merged: [{}], conflicts: [], testFailures: [], prsCreated: [] });

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

    expect(taskClient.update).not.toHaveBeenCalled();
  });

  it("is non-fatal when taskClient.update throws", async () => {
    const store = makeStore({
      getRun: vi.fn().mockReturnValue({ id: "run-1", status: "merged" }),
    });
    const taskClient = makeTaskClient({
      update: vi.fn().mockRejectedValue(new Error("br not found")),
    });

    await expect(
      syncBeadStatusAfterMerge(store as never, taskClient as never, "run-1", "bd-x", "/proj"),
    ).resolves.not.toThrow();

    expect(console.warn).toHaveBeenCalled();
  });

  it("is non-fatal when execFileSync (br sync) throws", async () => {
    const store = makeStore({
      getRun: vi.fn().mockReturnValue({ id: "run-1", status: "merged" }),
    });
    const taskClient = makeTaskClient({ update: vi.fn().mockResolvedValue(undefined) });
    mockExecFileSync.mockImplementation(() => { throw new Error("br binary missing"); });

    await expect(
      syncBeadStatusAfterMerge(store as never, taskClient as never, "run-1", "bd-x", "/proj"),
    ).resolves.not.toThrow();
  });
});
