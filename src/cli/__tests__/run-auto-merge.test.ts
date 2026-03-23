/**
 * Tests for the auto-merge behavior added to `foreman run`.
 *
 * Verifies:
 * - autoMerge() returns {merged:0,conflicts:0,failed:0} when no project is registered
 * - autoMerge() reconciles and drains queue when project exists but queue is empty
 * - autoMerge() counts merged / conflict / failed results correctly
 * - autoMerge() catches per-entry refinery errors and increments failedCount without throwing
 * - The dispatch loop processes the merge queue after each watchRunsInk unless --no-auto-merge
 * - autoMerge errors are non-fatal — the dispatch loop continues
 * - autoMerge() immediately syncs bead status in br after each merge outcome (bd-k8tx)
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

// ── Hoisted mocks ────────────────────────────────────────────────────────────

const {
  mockExecFileSync,
  mockEnsureBrInstalled,
  MockBeadsRustClient,
  MockBvClient,
  mockDispatch,
  MockDispatcher,
  mockGetActiveRuns,
  mockGetProjectByPath,
  mockGetRunsByStatuses,
  mockGetRun,
  mockGetDb,
  MockForemanStore,
  mockWatchRunsInk,
  mockMergeQueueReconcile,
  mockMergeQueueDequeue,
  mockMergeQueueUpdateStatus,
  MockMergeQueue,
  mockRefineryMergeCompleted,
  MockRefinery,
  mockAddNotesToBead,
} = vi.hoisted(() => {
  const mockAddNotesToBead = vi.fn();
  const mockExecFileSync = vi.fn().mockReturnValue(Buffer.from(""));
  const mockEnsureBrInstalled = vi.fn().mockResolvedValue(undefined);
  const MockBeadsRustClient = vi.fn(function (this: Record<string, unknown>) {
    this.ensureBrInstalled = mockEnsureBrInstalled;
  });
  const MockBvClient = vi.fn(function () { /* noop */ });

  const mockDispatch = vi.fn();
  const MockDispatcher = vi.fn(function (this: Record<string, unknown>) {
    this.dispatch = mockDispatch;
    this.resumeRuns = vi.fn().mockResolvedValue({ resumed: [], skipped: [], activeAgents: 0 });
  });

  const mockGetActiveRuns = vi.fn().mockReturnValue([]);
  const mockGetProjectByPath = vi.fn().mockReturnValue(null);
  const mockGetRunsByStatuses = vi.fn().mockReturnValue([]);
  const mockGetRun = vi.fn().mockReturnValue(null);
  const mockGetDb = vi.fn().mockReturnValue({});
  const MockForemanStore = vi.fn(function (this: Record<string, unknown>) {
    this.close = vi.fn();
    this.getActiveRuns = mockGetActiveRuns;
    this.getProjectByPath = mockGetProjectByPath;
    this.getRunsByStatuses = mockGetRunsByStatuses;
    this.getRun = mockGetRun;
    this.getDb = mockGetDb;
    this.getSentinelConfig = vi.fn().mockReturnValue(null);
  });
  (MockForemanStore as any).forProject = vi.fn((...args: unknown[]) => new (MockForemanStore as any)(...args));

  const mockWatchRunsInk = vi.fn().mockResolvedValue({ detached: false });

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

  return {
    mockExecFileSync,
    mockEnsureBrInstalled,
    MockBeadsRustClient,
    MockBvClient,
    mockDispatch,
    MockDispatcher,
    mockGetActiveRuns,
    mockGetProjectByPath,
    mockGetRunsByStatuses,
    mockGetRun,
    mockGetDb,
    MockForemanStore,
    mockWatchRunsInk,
    mockMergeQueueReconcile,
    mockMergeQueueDequeue,
    mockMergeQueueUpdateStatus,
    MockMergeQueue,
    mockRefineryMergeCompleted,
    MockRefinery,
    mockAddNotesToBead,
  };
});

vi.mock("node:child_process", () => ({
  execFile: vi.fn(),
  execFileSync: mockExecFileSync,
  spawnSync: vi.fn().mockReturnValue({ status: 0 }),
}));
vi.mock("../../lib/beads-rust.js", () => ({ BeadsRustClient: MockBeadsRustClient }));
vi.mock("../../lib/bv.js", () => ({ BvClient: MockBvClient }));
vi.mock("../../orchestrator/dispatcher.js", () => ({ Dispatcher: MockDispatcher }));
vi.mock("../../lib/store.js", () => ({ ForemanStore: MockForemanStore }));
vi.mock("../../lib/git.js", () => ({
  getRepoRoot: vi.fn().mockResolvedValue("/mock/project"),
  detectDefaultBranch: vi.fn().mockResolvedValue("main"),
}));
vi.mock("../../orchestrator/notification-server.js", () => ({
  NotificationServer: vi.fn(function (this: Record<string, unknown>) {
    this.start = vi.fn().mockResolvedValue(undefined);
    this.stop = vi.fn().mockResolvedValue(undefined);
    this.url = "http://127.0.0.1:9999";
  }),
}));
vi.mock("../../orchestrator/notification-bus.js", () => ({ notificationBus: {} }));
vi.mock("../watch-ui.js", () => ({ watchRunsInk: (...args: unknown[]) => mockWatchRunsInk(...args) }));
vi.mock("../../orchestrator/merge-queue.js", () => ({ MergeQueue: MockMergeQueue }));
vi.mock("../../orchestrator/refinery.js", () => ({ Refinery: MockRefinery }));
vi.mock("../../orchestrator/task-backend-ops.js", () => ({ addNotesToBead: mockAddNotesToBead }));
vi.mock("../../orchestrator/pi-rpc-spawn-strategy.js", () => ({
  isPiAvailable: vi.fn().mockReturnValue(false),
  PiRpcSpawnStrategy: vi.fn(),
  PI_PHASE_CONFIGS: {},
  parsePiEvent: vi.fn().mockReturnValue(null),
}));

import { runCommand, autoMerge, type AutoMergeOpts } from "../commands/run.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

async function invokeRun(args: string[]): Promise<void> {
  await runCommand.parseAsync(args, { from: "user" });
}

function resetMocks(): void {
  vi.clearAllMocks();
  vi.spyOn(console, "log").mockImplementation(() => {});
  vi.spyOn(console, "error").mockImplementation(() => {});
  vi.spyOn(console, "warn").mockImplementation(() => {});

  mockExecFileSync.mockReturnValue(Buffer.from(""));
  mockEnsureBrInstalled.mockResolvedValue(undefined);
  MockBeadsRustClient.mockImplementation(function (this: Record<string, unknown>) {
    this.ensureBrInstalled = mockEnsureBrInstalled;
  });
  MockBvClient.mockImplementation(function () { /* noop */ });
  MockDispatcher.mockImplementation(function (this: Record<string, unknown>) {
    this.dispatch = mockDispatch;
    this.resumeRuns = vi.fn().mockResolvedValue({ resumed: [], skipped: [], activeAgents: 0 });
  });
  MockForemanStore.mockImplementation(function (this: Record<string, unknown>) {
    this.close = vi.fn();
    this.getActiveRuns = mockGetActiveRuns;
    this.getProjectByPath = mockGetProjectByPath;
    this.getRunsByStatuses = mockGetRunsByStatuses;
    this.getRun = mockGetRun;
    this.getDb = mockGetDb;
    this.getSentinelConfig = vi.fn().mockReturnValue(null);
  });
  MockMergeQueue.mockImplementation(function (this: Record<string, unknown>) {
    this.reconcile = mockMergeQueueReconcile;
    this.dequeue = mockMergeQueueDequeue;
    this.updateStatus = mockMergeQueueUpdateStatus;
  });
  MockRefinery.mockImplementation(function (this: Record<string, unknown>) {
    this.mergeCompleted = mockRefineryMergeCompleted;
  });

  mockWatchRunsInk.mockResolvedValue({ detached: false });
  mockGetActiveRuns.mockReturnValue([]);
  mockGetProjectByPath.mockReturnValue(null);
  mockGetRunsByStatuses.mockReturnValue([]);
  mockGetRun.mockReturnValue(null);
  mockGetDb.mockReturnValue({});
  mockMergeQueueReconcile.mockResolvedValue({ enqueued: 0, skipped: 0, invalidBranch: 0 });
  mockMergeQueueDequeue.mockReturnValue(null);
  mockMergeQueueUpdateStatus.mockReturnValue(undefined);
  mockRefineryMergeCompleted.mockResolvedValue({
    merged: [],
    conflicts: [],
    testFailures: [],
    prsCreated: [],
  });
}

// ── Unit tests for autoMerge() ────────────────────────────────────────────────

describe("autoMerge() unit tests", () => {
  beforeEach(resetMocks);
  afterEach(() => vi.restoreAllMocks());

  function makeStore(): ReturnType<typeof MockForemanStore> {
    return new MockForemanStore() as ReturnType<typeof MockForemanStore>;
  }

  it("returns zeros immediately when no project is registered", async () => {
    mockGetProjectByPath.mockReturnValue(null);

    const store = makeStore();
    const result = await autoMerge({
      store: store as never,
      taskClient: {} as never,
      projectPath: "/any/path",
    } satisfies AutoMergeOpts);

    expect(result).toEqual({ merged: 0, conflicts: 0, failed: 0 });
    // reconcile should NOT have been called — no project means no work
    expect(mockMergeQueueReconcile).not.toHaveBeenCalled();
  });

  it("returns zeros when queue is empty after reconcile", async () => {
    mockGetProjectByPath.mockReturnValue({ id: "p1", path: "/mock/project" });
    mockMergeQueueReconcile.mockResolvedValue({ enqueued: 0, skipped: 0, invalidBranch: 0 });
    mockMergeQueueDequeue.mockReturnValue(null);

    const store = makeStore();
    const result = await autoMerge({
      store: store as never,
      taskClient: {} as never,
      projectPath: "/mock/project",
    });

    expect(result).toEqual({ merged: 0, conflicts: 0, failed: 0 });
    expect(mockMergeQueueReconcile).toHaveBeenCalledOnce();
  });

  it("counts merged results from refinery report", async () => {
    mockGetProjectByPath.mockReturnValue({ id: "p1", path: "/mock/project" });

    const fakeEntry = {
      id: 1, branch_name: "foreman/s1", seed_id: "s1", run_id: "r1",
      agent_name: null, files_modified: [], enqueued_at: new Date().toISOString(),
      started_at: null, completed_at: null, status: "merging" as const,
      resolved_tier: null, error: null,
    };
    mockMergeQueueDequeue
      .mockReturnValueOnce(fakeEntry)
      .mockReturnValue(null);

    mockRefineryMergeCompleted.mockResolvedValue({
      merged: [{ runId: "r1", seedId: "s1", branchName: "foreman/s1" }],
      conflicts: [],
      testFailures: [],
      prsCreated: [],
    });

    const store = makeStore();
    const result = await autoMerge({ store: store as never, taskClient: {} as never, projectPath: "/mock/project" });

    expect(result.merged).toBe(1);
    expect(result.conflicts).toBe(0);
    expect(result.failed).toBe(0);
    expect(mockMergeQueueUpdateStatus).toHaveBeenCalledWith(1, "merged", expect.objectContaining({ completedAt: expect.any(String) }));
  });

  it("counts conflict results from refinery report", async () => {
    mockGetProjectByPath.mockReturnValue({ id: "p1", path: "/mock/project" });

    const fakeEntry = {
      id: 2, branch_name: "foreman/s2", seed_id: "s2", run_id: "r2",
      agent_name: null, files_modified: [], enqueued_at: new Date().toISOString(),
      started_at: null, completed_at: null, status: "merging" as const,
      resolved_tier: null, error: null,
    };
    mockMergeQueueDequeue
      .mockReturnValueOnce(fakeEntry)
      .mockReturnValue(null);

    mockRefineryMergeCompleted.mockResolvedValue({
      merged: [],
      conflicts: [{ runId: "r2", seedId: "s2", branchName: "foreman/s2", conflictFiles: ["src/a.ts"] }],
      testFailures: [],
      prsCreated: [],
    });

    const store = makeStore();
    const result = await autoMerge({ store: store as never, taskClient: {} as never, projectPath: "/mock/project" });

    expect(result.merged).toBe(0);
    expect(result.conflicts).toBe(1);
    expect(result.failed).toBe(0);
    expect(mockMergeQueueUpdateStatus).toHaveBeenCalledWith(2, "conflict", expect.objectContaining({ error: "Code conflicts" }));
  });

  it("counts failed results when refinery throws (non-fatal per-entry catch)", async () => {
    mockGetProjectByPath.mockReturnValue({ id: "p1", path: "/mock/project" });

    const fakeEntry = {
      id: 3, branch_name: "foreman/s3", seed_id: "s3", run_id: "r3",
      agent_name: null, files_modified: [], enqueued_at: new Date().toISOString(),
      started_at: null, completed_at: null, status: "merging" as const,
      resolved_tier: null, error: null,
    };
    mockMergeQueueDequeue
      .mockReturnValueOnce(fakeEntry)
      .mockReturnValue(null);

    mockRefineryMergeCompleted.mockRejectedValue(new Error("git exploded"));

    const store = makeStore();
    // Should NOT throw — catches the error internally
    const result = await autoMerge({ store: store as never, taskClient: {} as never, projectPath: "/mock/project" });

    expect(result.failed).toBe(1);
    expect(result.merged).toBe(0);
    expect(mockMergeQueueUpdateStatus).toHaveBeenCalledWith(3, "failed", expect.objectContaining({ error: "git exploded" }));
  });

  it("counts failed results when refinery returns no report entries", async () => {
    mockGetProjectByPath.mockReturnValue({ id: "p1", path: "/mock/project" });

    const fakeEntry = {
      id: 4, branch_name: "foreman/s4", seed_id: "s4", run_id: "r4",
      agent_name: null, files_modified: [], enqueued_at: new Date().toISOString(),
      started_at: null, completed_at: null, status: "merging" as const,
      resolved_tier: null, error: null,
    };
    mockMergeQueueDequeue
      .mockReturnValueOnce(fakeEntry)
      .mockReturnValue(null);

    // All empty — "no completed run found" branch
    mockRefineryMergeCompleted.mockResolvedValue({
      merged: [],
      conflicts: [],
      testFailures: [],
      prsCreated: [],
    });

    const store = makeStore();
    const result = await autoMerge({ store: store as never, taskClient: {} as never, projectPath: "/mock/project" });

    expect(result.failed).toBe(1);
    expect(mockMergeQueueUpdateStatus).toHaveBeenCalledWith(4, "failed", expect.objectContaining({ error: "No completed run found" }));
  });

  it("processes multiple queue entries and accumulates counts", async () => {
    mockGetProjectByPath.mockReturnValue({ id: "p1", path: "/mock/project" });

    const entryA = { id: 10, branch_name: "foreman/a", seed_id: "a", run_id: "ra", agent_name: null, files_modified: [], enqueued_at: new Date().toISOString(), started_at: null, completed_at: null, status: "merging" as const, resolved_tier: null, error: null };
    const entryB = { id: 11, branch_name: "foreman/b", seed_id: "b", run_id: "rb", agent_name: null, files_modified: [], enqueued_at: new Date().toISOString(), started_at: null, completed_at: null, status: "merging" as const, resolved_tier: null, error: null };
    const entryC = { id: 12, branch_name: "foreman/c", seed_id: "c", run_id: "rc", agent_name: null, files_modified: [], enqueued_at: new Date().toISOString(), started_at: null, completed_at: null, status: "merging" as const, resolved_tier: null, error: null };

    mockMergeQueueDequeue
      .mockReturnValueOnce(entryA)
      .mockReturnValueOnce(entryB)
      .mockReturnValueOnce(entryC)
      .mockReturnValue(null);

    mockRefineryMergeCompleted
      .mockResolvedValueOnce({ merged: [{ runId: "ra", seedId: "a", branchName: "foreman/a" }], conflicts: [], testFailures: [], prsCreated: [] })
      .mockResolvedValueOnce({ merged: [], conflicts: [{ runId: "rb", seedId: "b", branchName: "foreman/b", conflictFiles: [] }], testFailures: [], prsCreated: [] })
      .mockRejectedValueOnce(new Error("boom"));

    const store = makeStore();
    const result = await autoMerge({ store: store as never, taskClient: {} as never, projectPath: "/mock/project" });

    expect(result.merged).toBe(1);
    expect(result.conflicts).toBe(1);
    expect(result.failed).toBe(1);
  });
});

// ── Dispatch loop integration: auto-merge is called (or not) correctly ────────

describe("dispatch loop: auto-merge after each batch", () => {
  beforeEach(resetMocks);
  afterEach(() => vi.restoreAllMocks());

  it("processes merge queue after normal batch watch completes (auto-merge enabled by default)", async () => {
    mockGetProjectByPath.mockReturnValue({ id: "p1", path: "/mock/project" });

    // Dispatch 1 task; --no-watch exits immediately after dispatch without polling.
    // Final merge drain runs once after the dispatch loop exits.
    mockDispatch.mockResolvedValueOnce({
      dispatched: [
        {
          seedId: "s-1", runId: "run-111", title: "Task 1",
          model: "claude-sonnet-4-6", worktreePath: "/tmp/wt",
          branchName: "foreman/s-1", runtime: "claude-code",
        },
      ],
      skipped: [],
      activeAgents: 1,
    });

    await invokeRun(["--no-watch"]);

    // MergeQueue.reconcile is called twice: once in the startup drain, once in the final drain.
    expect(mockMergeQueueReconcile).toHaveBeenCalledTimes(2);
  });

  it("processes merge queue after waiting-for-active-agents watch completes", async () => {
    mockGetProjectByPath.mockReturnValue({ id: "p1", path: "/mock/project" });

    // With --no-watch, dispatch exits immediately; final merge drain runs once.
    mockDispatch.mockResolvedValueOnce({ dispatched: [], skipped: [], activeAgents: 0 });

    await invokeRun(["--no-watch"]);

    // MergeQueue.reconcile is called twice: once in the startup drain, once in the final drain.
    expect(mockMergeQueueReconcile).toHaveBeenCalledTimes(2);
  });

  it("does NOT process merge queue when --no-auto-merge is set", async () => {
    mockDispatch.mockResolvedValueOnce({
      dispatched: [
        {
          seedId: "s-2", runId: "run-222", title: "Task 2",
          model: "claude-sonnet-4-6", worktreePath: "/tmp/wt",
          branchName: "foreman/s-2", runtime: "claude-code",
        },
      ],
      skipped: [],
      activeAgents: 1,
    });

    await invokeRun(["--no-auto-merge", "--no-watch"]);

    expect(mockMergeQueueReconcile).not.toHaveBeenCalled();
    expect(MockMergeQueue).not.toHaveBeenCalled();
  });

  it("continues dispatch loop even when autoMerge internals throw (non-fatal)", async () => {
    mockGetProjectByPath.mockReturnValue({ id: "p1", path: "/mock/project" });
    // Make reconcile throw to simulate a broken merge system
    mockMergeQueueReconcile.mockRejectedValueOnce(new Error("merge system down"));

    mockDispatch.mockResolvedValueOnce({
      dispatched: [
        {
          seedId: "s-3", runId: "run-333", title: "Task 3",
          model: "claude-sonnet-4-6", worktreePath: "/tmp/wt",
          branchName: "foreman/s-3", runtime: "claude-code",
        },
      ],
      skipped: [],
      activeAgents: 1,
    });

    // Should not throw — auto-merge errors are non-fatal (--no-watch for immediate exit)
    await expect(invokeRun(["--no-watch"])).resolves.toBeUndefined();

    // dispatch called once in --no-watch mode; error is caught and logged
    expect(mockDispatch).toHaveBeenCalledTimes(1);
  });

  it("does NOT process merge queue in --dry-run mode", async () => {
    mockDispatch.mockResolvedValue({ dispatched: [], skipped: [], activeAgents: 0 });

    await invokeRun(["--dry-run"]);

    expect(MockMergeQueue).not.toHaveBeenCalled();
    expect(mockMergeQueueReconcile).not.toHaveBeenCalled();
  });

  it("processes merge queue BEFORE watchRunsInk even when user detaches (Ctrl+C)", async () => {
    mockGetProjectByPath.mockReturnValue({ id: "p1", path: "/mock/project" });
    mockWatchRunsInk.mockResolvedValue({ detached: true });

    mockDispatch.mockResolvedValueOnce({
      dispatched: [
        {
          seedId: "s-4", runId: "run-444", title: "Task 4",
          model: "claude-sonnet-4-6", worktreePath: "/tmp/wt",
          branchName: "foreman/s-4", runtime: "claude-code",
        },
      ],
      skipped: [],
      activeAgents: 1,
    });

    await invokeRun([]);

    // autoMerge now runs BEFORE watchRunsInk — so reconcile is called even when detached
    // (only the final drain after the loop is skipped when detached)
    // startup drain + in-loop (before watch) = 2 calls; final drain skipped
    expect(mockMergeQueueReconcile).toHaveBeenCalledTimes(2);
  });

  it("logs 'Auto-merging completed branches...' and merged count", async () => {
    const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

    mockGetProjectByPath.mockReturnValue({ id: "p1", path: "/mock/project" });

    // Return 2 merged entries from the queue
    const fakeEntry = {
      id: 20, branch_name: "foreman/sx", seed_id: "sx", run_id: "rx",
      agent_name: null, files_modified: [], enqueued_at: new Date().toISOString(),
      started_at: null, completed_at: null, status: "merging" as const,
      resolved_tier: null, error: null,
    };
    mockMergeQueueDequeue
      .mockReturnValueOnce(null)    // startup drain: empty queue
      .mockReturnValueOnce(fakeEntry)
      .mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValue({
      merged: [
        { runId: "rx", seedId: "sx", branchName: "foreman/sx" },
        { runId: "rx2", seedId: "sx2", branchName: "foreman/sx2" },
      ],
      conflicts: [],
      testFailures: [],
      prsCreated: [],
    });

    mockDispatch.mockResolvedValueOnce({
      dispatched: [
        {
          seedId: "sx", runId: "run-x", title: "Task X",
          model: "claude-sonnet-4-6", worktreePath: "/tmp/wt",
          branchName: "foreman/sx", runtime: "claude-code",
        },
      ],
      skipped: [],
      activeAgents: 1,
    });

    await invokeRun(["--no-watch"]);

    const logCalls = consoleSpy.mock.calls.map((c) => String(c[0]));
    // In --no-watch mode, the final drain prints "Processing remaining merge queue entries..."
    // rather than "Auto-merging completed branches..." (which is for the in-loop autoMerge).
    const hasAutoMergeHeader = logCalls.some((m) =>
      m.includes("Auto-merging completed branches") ||
      m.includes("Processing remaining merge queue entries")
    );
    const hasMergedCount = logCalls.some((m) => m.includes("Auto-merged 2 branch(es)"));

    expect(hasAutoMergeHeader).toBe(true);
    expect(hasMergedCount).toBe(true);

    consoleSpy.mockRestore();
  });

  it("logs conflict warning when conflicts occur", async () => {
    const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

    mockGetProjectByPath.mockReturnValue({ id: "p1", path: "/mock/project" });

    const fakeEntry = {
      id: 30, branch_name: "foreman/sy", seed_id: "sy", run_id: "ry",
      agent_name: null, files_modified: [], enqueued_at: new Date().toISOString(),
      started_at: null, completed_at: null, status: "merging" as const,
      resolved_tier: null, error: null,
    };
    mockMergeQueueDequeue
      .mockReturnValueOnce(null)    // startup drain: empty queue
      .mockReturnValueOnce(fakeEntry)
      .mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValue({
      merged: [],
      conflicts: [{ runId: "ry", seedId: "sy", branchName: "foreman/sy", conflictFiles: ["x.ts"] }],
      testFailures: [],
      prsCreated: [],
    });

    mockDispatch.mockResolvedValueOnce({
      dispatched: [
        {
          seedId: "sy", runId: "run-y", title: "Task Y",
          model: "claude-sonnet-4-6", worktreePath: "/tmp/wt",
          branchName: "foreman/sy", runtime: "claude-code",
        },
      ],
      skipped: [],
      activeAgents: 1,
    });

    await invokeRun(["--no-watch"]);

    const logCalls = consoleSpy.mock.calls.map((c) => String(c[0]));
    const hasConflictLog = logCalls.some((m) => m.includes("conflict(s)"));

    expect(hasConflictLog).toBe(true);

    consoleSpy.mockRestore();
  });
});

// ── Call ordering: autoMerge must run BEFORE watchRunsInk ────────────────────
//
// Regression tests for the bug where autoMerge was called after watchRunsInk
// returned, causing completed branches to sit unmerged while long-running
// agents occupied the watch.

describe("call ordering: autoMerge fires BEFORE watchRunsInk", () => {
  beforeEach(resetMocks);
  afterEach(() => vi.restoreAllMocks());

  it("calls autoMerge before watchRunsInk at callsite 1 (no tasks dispatched, agents active)", async () => {
    mockGetProjectByPath.mockReturnValue({ id: "p1", path: "/mock/project" });

    // Nothing dispatched, but 1 active agent — triggers callsite 1 (waiting path).
    // watchRunsInk returns detached=true → loop breaks immediately, no 2nd dispatch.
    mockDispatch.mockResolvedValueOnce({ dispatched: [], skipped: [], activeAgents: 1 });
    mockGetActiveRuns.mockReturnValue([{ id: "run-active" }]);

    const callOrder: string[] = [];
    mockMergeQueueReconcile.mockImplementation(async () => {
      callOrder.push("autoMerge");
      return { enqueued: 0, skipped: 0, invalidBranch: 0 };
    });
    mockWatchRunsInk.mockImplementationOnce(async () => {
      callOrder.push("watchRunsInk");
      return { detached: true }; // detach to exit loop cleanly
    });

    await invokeRun([]);

    // autoMerge (via reconcile) should have been called BEFORE watchRunsInk
    const autoMergeIdx = callOrder.indexOf("autoMerge");
    const watchIdx = callOrder.indexOf("watchRunsInk");
    expect(autoMergeIdx).toBeGreaterThanOrEqual(0);
    expect(watchIdx).toBeGreaterThanOrEqual(0);
    expect(autoMergeIdx).toBeLessThan(watchIdx);
  });

  it("calls autoMerge before watchRunsInk at callsite 2 (tasks dispatched, watch mode)", async () => {
    mockGetProjectByPath.mockReturnValue({ id: "p1", path: "/mock/project" });

    // Tasks dispatched — triggers callsite 2 (normal dispatch + watch path)
    mockDispatch.mockResolvedValueOnce({
      dispatched: [
        {
          seedId: "s-ord", runId: "run-ord", title: "Order Test",
          model: "claude-sonnet-4-6", worktreePath: "/tmp/wt",
          branchName: "foreman/s-ord", runtime: "claude-code",
        },
      ],
      skipped: [],
      activeAgents: 1,
    });

    // Detach on watch to exit cleanly
    mockWatchRunsInk.mockResolvedValue({ detached: true });

    const callOrder: string[] = [];
    mockMergeQueueReconcile.mockImplementation(async () => {
      callOrder.push("autoMerge");
      return { enqueued: 0, skipped: 0, invalidBranch: 0 };
    });
    mockWatchRunsInk.mockImplementationOnce(async () => {
      callOrder.push("watchRunsInk");
      return { detached: true };
    });

    await invokeRun([]);

    // autoMerge (via reconcile) must appear before watchRunsInk in call order
    const autoMergeIdx = callOrder.indexOf("autoMerge");
    const watchIdx = callOrder.indexOf("watchRunsInk");
    expect(autoMergeIdx).toBeGreaterThanOrEqual(0);
    expect(watchIdx).toBeGreaterThanOrEqual(0);
    expect(autoMergeIdx).toBeLessThan(watchIdx);
  });
});

// ── Final merge drain: pending entries processed after dispatch loop exits ────

describe("final merge drain: continuous processing after dispatch loop", () => {
  beforeEach(resetMocks);
  afterEach(() => vi.restoreAllMocks());

  it("processes pending merge queue entries that arrived after the last in-loop autoMerge", async () => {
    mockGetProjectByPath.mockReturnValue({ id: "p1", path: "/mock/project" });

    // With --no-watch, the dispatch loop exits immediately after dispatch.
    // The final drain finds a previously-queued entry.
    const lateEntry = {
      id: 99, branch_name: "foreman/late", seed_id: "late", run_id: "r-late",
      agent_name: null, files_modified: [], enqueued_at: new Date().toISOString(),
      started_at: null, completed_at: null, status: "merging" as const,
      resolved_tier: null, error: null,
    };

    // Final drain dequeue: startup gets null, final drain gets the pending entry
    mockMergeQueueDequeue
      .mockReturnValueOnce(null)    // startup drain: empty queue
      .mockReturnValueOnce(lateEntry)
      .mockReturnValue(null);

    mockRefineryMergeCompleted.mockResolvedValue({
      merged: [{ runId: "r-late", seedId: "late", branchName: "foreman/late" }],
      conflicts: [],
      testFailures: [],
      prsCreated: [],
    });

    mockDispatch.mockResolvedValueOnce({
      dispatched: [
        {
          seedId: "s-10", runId: "run-1010", title: "Task 10",
          model: "claude-sonnet-4-6", worktreePath: "/tmp/wt",
          branchName: "foreman/s-10", runtime: "claude-code",
        },
      ],
      skipped: [],
      activeAgents: 1,
    });

    await invokeRun(["--no-watch"]);

    // reconcile called twice: startup drain + final drain
    expect(mockMergeQueueReconcile).toHaveBeenCalledTimes(2);
    // The pending entry should have been processed in the final drain
    expect(mockMergeQueueUpdateStatus).toHaveBeenCalledWith(99, "merged", expect.objectContaining({ completedAt: expect.any(String) }));
  });

  it("final drain logs results when entries are processed", async () => {
    const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    mockGetProjectByPath.mockReturnValue({ id: "p1", path: "/mock/project" });

    const lateEntry = {
      id: 100, branch_name: "foreman/z", seed_id: "z", run_id: "r-z",
      agent_name: null, files_modified: [], enqueued_at: new Date().toISOString(),
      started_at: null, completed_at: null, status: "merging" as const,
      resolved_tier: null, error: null,
    };

    // Startup drain: empty; final drain finds the entry
    mockMergeQueueDequeue
      .mockReturnValueOnce(null)    // startup drain: empty queue
      .mockReturnValueOnce(lateEntry)
      .mockReturnValue(null);

    mockRefineryMergeCompleted.mockResolvedValue({
      merged: [{ runId: "r-z", seedId: "z", branchName: "foreman/z" }],
      conflicts: [],
      testFailures: [],
      prsCreated: [],
    });

    mockDispatch.mockResolvedValueOnce({
      dispatched: [{ seedId: "s-z", runId: "run-z", title: "Z", model: "claude-sonnet-4-6", worktreePath: "/tmp/wt", branchName: "foreman/z", runtime: "claude-code" }],
      skipped: [],
      activeAgents: 1,
    });

    await invokeRun(["--no-watch"]);

    const logCalls = consoleSpy.mock.calls.map((c) => String(c[0]));
    const hasRemainingLog = logCalls.some((m) => m.includes("Processing remaining merge queue entries"));
    const hasMergedCount = logCalls.some((m) => m.includes("Auto-merged 1 branch(es)"));

    expect(hasRemainingLog).toBe(true);
    expect(hasMergedCount).toBe(true);

    consoleSpy.mockRestore();
  });

  it("final drain is skipped when user detaches (Ctrl+C), but in-loop autoMerge still ran before watch", async () => {
    mockGetProjectByPath.mockReturnValue({ id: "p1", path: "/mock/project" });
    // User detaches during watch
    mockWatchRunsInk.mockResolvedValue({ detached: true });

    mockDispatch.mockResolvedValueOnce({
      dispatched: [
        {
          seedId: "s-det", runId: "run-det", title: "Detach Task",
          model: "claude-sonnet-4-6", worktreePath: "/tmp/wt",
          branchName: "foreman/s-det", runtime: "claude-code",
        },
      ],
      skipped: [],
      activeAgents: 1,
    });

    await invokeRun([]);

    // autoMerge now runs BEFORE watchRunsInk — startup drain + in-loop (before watch) = 2 calls
    // The final drain after the loop is skipped (userDetached=true)
    expect(mockMergeQueueReconcile).toHaveBeenCalledTimes(2);
  });

  it("final drain is skipped when --no-auto-merge is set", async () => {
    mockGetProjectByPath.mockReturnValue({ id: "p1", path: "/mock/project" });

    mockDispatch.mockResolvedValueOnce({
      dispatched: [{ seedId: "s-nm", runId: "run-nm", title: "No Merge", model: "claude-sonnet-4-6", worktreePath: "/tmp/wt", branchName: "foreman/s-nm", runtime: "claude-code" }],
      skipped: [],
      activeAgents: 1,
    });

    await invokeRun(["--no-auto-merge", "--no-watch"]);

    // No merge queue operations at all
    expect(mockMergeQueueReconcile).not.toHaveBeenCalled();
    expect(MockMergeQueue).not.toHaveBeenCalled();
  });

  it("final drain is skipped in --dry-run mode", async () => {
    mockDispatch.mockResolvedValue({ dispatched: [], skipped: [], activeAgents: 0 });

    await invokeRun(["--dry-run"]);

    expect(MockMergeQueue).not.toHaveBeenCalled();
    expect(mockMergeQueueReconcile).not.toHaveBeenCalled();
  });

  it("final drain processes queue in --no-watch mode when pending entries exist", async () => {
    mockGetProjectByPath.mockReturnValue({ id: "p1", path: "/mock/project" });

    const pendingEntry = {
      id: 200, branch_name: "foreman/prev", seed_id: "prev", run_id: "r-prev",
      agent_name: null, files_modified: [], enqueued_at: new Date().toISOString(),
      started_at: null, completed_at: null, status: "merging" as const,
      resolved_tier: null, error: null,
    };

    // In --no-watch mode, the in-loop autoMerge is never called.
    // Startup drain: empty; final drain finds the previously-queued entry.
    mockMergeQueueDequeue
      .mockReturnValueOnce(null)    // startup drain: empty queue
      .mockReturnValueOnce(pendingEntry)
      .mockReturnValue(null);

    mockRefineryMergeCompleted.mockResolvedValue({
      merged: [{ runId: "r-prev", seedId: "prev", branchName: "foreman/prev" }],
      conflicts: [],
      testFailures: [],
      prsCreated: [],
    });

    mockDispatch.mockResolvedValueOnce({
      dispatched: [
        {
          seedId: "s-nw", runId: "run-nw", title: "No Watch Task",
          model: "claude-sonnet-4-6", worktreePath: "/tmp/wt",
          branchName: "foreman/s-nw", runtime: "claude-code",
        },
      ],
      skipped: [],
      activeAgents: 1,
    });

    await invokeRun(["--no-watch"]);

    // Final drain should have processed the pending entry; reconcile: startup + final = 2
    expect(mockMergeQueueReconcile).toHaveBeenCalledTimes(2);
    expect(mockMergeQueueUpdateStatus).toHaveBeenCalledWith(200, "merged", expect.objectContaining({ completedAt: expect.any(String) }));
  });

  it("final drain errors are non-fatal — command still exits cleanly", async () => {
    mockGetProjectByPath.mockReturnValue({ id: "p1", path: "/mock/project" });
    // Make the final drain's reconcile throw
    mockMergeQueueReconcile.mockRejectedValueOnce(new Error("drain error"));

    mockDispatch.mockResolvedValueOnce({
      dispatched: [
        {
          seedId: "s-fe", runId: "run-fe", title: "Fatal Error Task",
          model: "claude-sonnet-4-6", worktreePath: "/tmp/wt",
          branchName: "foreman/s-fe", runtime: "claude-code",
        },
      ],
      skipped: [],
      activeAgents: 1,
    });

    // Should NOT throw — final drain errors are non-fatal (--no-watch for immediate exit)
    await expect(invokeRun(["--no-watch"])).resolves.toBeUndefined();
    expect(mockDispatch).toHaveBeenCalledTimes(1);
  });
});

// ── Bead status sync after merge (bd-k8tx) ────────────────────────────────────
//
// Verifies that autoMerge() immediately updates the bead status in br after
// each merge outcome, rather than waiting for the next foreman startup.

describe("autoMerge() — immediate bead status sync", () => {
  beforeEach(resetMocks);
  afterEach(() => vi.restoreAllMocks());

  function makeStore(): ReturnType<typeof MockForemanStore> {
    return new MockForemanStore() as ReturnType<typeof MockForemanStore>;
  }

  it("calls taskClient.update() with status 'closed' when run status is 'merged'", async () => {
    mockGetProjectByPath.mockReturnValue({ id: "p1", path: "/mock/project" });

    const fakeEntry = {
      id: 1, branch_name: "foreman/s1", seed_id: "s1", run_id: "r1",
      agent_name: null, files_modified: [], enqueued_at: new Date().toISOString(),
      started_at: null, completed_at: null, status: "merging" as const,
      resolved_tier: null, error: null,
    };
    mockMergeQueueDequeue
      .mockReturnValueOnce(fakeEntry)
      .mockReturnValue(null);

    // Refinery reports a successful merge
    mockRefineryMergeCompleted.mockResolvedValue({
      merged: [{ runId: "r1", seedId: "s1", branchName: "foreman/s1" }],
      conflicts: [], testFailures: [], prsCreated: [],
    });

    // Store returns the run with status 'merged' after refinery completes
    mockGetRun.mockReturnValue({ id: "r1", seed_id: "s1", status: "merged" });

    const mockUpdate = vi.fn().mockResolvedValue(undefined);
    const store = makeStore();
    const result = await autoMerge({
      store: store as never,
      taskClient: { update: mockUpdate } as never,
      projectPath: "/mock/project",
    });

    expect(result.merged).toBe(1);
    expect(mockUpdate).toHaveBeenCalledWith("s1", { status: "closed" });
    // br sync --flush-only should have been called
    expect(mockExecFileSync).toHaveBeenCalledWith(
      expect.stringContaining("br"),
      ["sync", "--flush-only"],
      expect.objectContaining({ stdio: "pipe" }),
    );
  });

  it("calls taskClient.update() with status 'blocked' when run status is 'conflict'", async () => {
    mockGetProjectByPath.mockReturnValue({ id: "p1", path: "/mock/project" });

    const fakeEntry = {
      id: 2, branch_name: "foreman/s2", seed_id: "s2", run_id: "r2",
      agent_name: null, files_modified: [], enqueued_at: new Date().toISOString(),
      started_at: null, completed_at: null, status: "merging" as const,
      resolved_tier: null, error: null,
    };
    mockMergeQueueDequeue
      .mockReturnValueOnce(fakeEntry)
      .mockReturnValue(null);

    mockRefineryMergeCompleted.mockResolvedValue({
      merged: [],
      conflicts: [{ runId: "r2", seedId: "s2", branchName: "foreman/s2", conflictFiles: ["x.ts"] }],
      testFailures: [], prsCreated: [],
    });

    // Run status after refinery is 'conflict'
    mockGetRun.mockReturnValue({ id: "r2", seed_id: "s2", status: "conflict" });

    const mockUpdate = vi.fn().mockResolvedValue(undefined);
    const store = makeStore();
    await autoMerge({
      store: store as never,
      taskClient: { update: mockUpdate } as never,
      projectPath: "/mock/project",
    });

    expect(mockUpdate).toHaveBeenCalledWith("s2", { status: "blocked" });
  });

  it("calls taskClient.update() with status 'blocked' when run status is 'test-failed'", async () => {
    mockGetProjectByPath.mockReturnValue({ id: "p1", path: "/mock/project" });

    const fakeEntry = {
      id: 3, branch_name: "foreman/s3", seed_id: "s3", run_id: "r3",
      agent_name: null, files_modified: [], enqueued_at: new Date().toISOString(),
      started_at: null, completed_at: null, status: "merging" as const,
      resolved_tier: null, error: null,
    };
    mockMergeQueueDequeue
      .mockReturnValueOnce(fakeEntry)
      .mockReturnValue(null);

    mockRefineryMergeCompleted.mockResolvedValue({
      merged: [], conflicts: [],
      testFailures: [{ runId: "r3", seedId: "s3", branchName: "foreman/s3", error: "Tests failed" }],
      prsCreated: [],
    });

    mockGetRun.mockReturnValue({ id: "r3", seed_id: "s3", status: "test-failed" });

    const mockUpdate = vi.fn().mockResolvedValue(undefined);
    const store = makeStore();
    await autoMerge({
      store: store as never,
      taskClient: { update: mockUpdate } as never,
      projectPath: "/mock/project",
    });

    expect(mockUpdate).toHaveBeenCalledWith("s3", { status: "blocked" });
  });

  it("calls taskClient.update() with status 'failed' when refinery throws (exception path)", async () => {
    mockGetProjectByPath.mockReturnValue({ id: "p1", path: "/mock/project" });

    const fakeEntry = {
      id: 4, branch_name: "foreman/s4", seed_id: "s4", run_id: "r4",
      agent_name: null, files_modified: [], enqueued_at: new Date().toISOString(),
      started_at: null, completed_at: null, status: "merging" as const,
      resolved_tier: null, error: null,
    };
    mockMergeQueueDequeue
      .mockReturnValueOnce(fakeEntry)
      .mockReturnValue(null);

    mockRefineryMergeCompleted.mockRejectedValue(new Error("git exploded"));

    // Run has status 'failed' (set by refinery exception handler in refinery.ts)
    mockGetRun.mockReturnValue({ id: "r4", seed_id: "s4", status: "failed" });

    const mockUpdate = vi.fn().mockResolvedValue(undefined);
    const store = makeStore();
    const result = await autoMerge({
      store: store as never,
      taskClient: { update: mockUpdate } as never,
      projectPath: "/mock/project",
    });

    expect(result.failed).toBe(1);
    expect(mockUpdate).toHaveBeenCalledWith("s4", { status: "failed" });
  });

  it("skips bead update when getRun returns null (no run found)", async () => {
    mockGetProjectByPath.mockReturnValue({ id: "p1", path: "/mock/project" });

    const fakeEntry = {
      id: 5, branch_name: "foreman/s5", seed_id: "s5", run_id: "r5",
      agent_name: null, files_modified: [], enqueued_at: new Date().toISOString(),
      started_at: null, completed_at: null, status: "merging" as const,
      resolved_tier: null, error: null,
    };
    mockMergeQueueDequeue
      .mockReturnValueOnce(fakeEntry)
      .mockReturnValue(null);

    mockRefineryMergeCompleted.mockResolvedValue({
      merged: [{ runId: "r5", seedId: "s5", branchName: "foreman/s5" }],
      conflicts: [], testFailures: [], prsCreated: [],
    });

    // Run not found (deleted between refinery and sync)
    mockGetRun.mockReturnValue(null);

    const mockUpdate = vi.fn().mockResolvedValue(undefined);
    const store = makeStore();
    await autoMerge({
      store: store as never,
      taskClient: { update: mockUpdate } as never,
      projectPath: "/mock/project",
    });

    // update should NOT have been called since no run was found
    expect(mockUpdate).not.toHaveBeenCalled();
    expect(mockExecFileSync).not.toHaveBeenCalled();
  });

  it("is non-fatal: continues when taskClient.update() throws", async () => {
    mockGetProjectByPath.mockReturnValue({ id: "p1", path: "/mock/project" });

    const fakeEntry = {
      id: 6, branch_name: "foreman/s6", seed_id: "s6", run_id: "r6",
      agent_name: null, files_modified: [], enqueued_at: new Date().toISOString(),
      started_at: null, completed_at: null, status: "merging" as const,
      resolved_tier: null, error: null,
    };
    mockMergeQueueDequeue
      .mockReturnValueOnce(fakeEntry)
      .mockReturnValue(null);

    mockRefineryMergeCompleted.mockResolvedValue({
      merged: [{ runId: "r6", seedId: "s6", branchName: "foreman/s6" }],
      conflicts: [], testFailures: [], prsCreated: [],
    });

    mockGetRun.mockReturnValue({ id: "r6", seed_id: "s6", status: "merged" });

    const mockUpdate = vi.fn().mockRejectedValue(new Error("br binary missing"));
    const store = makeStore();

    // Should NOT throw — bead sync is non-fatal
    await expect(
      autoMerge({
        store: store as never,
        taskClient: { update: mockUpdate } as never,
        projectPath: "/mock/project",
      })
    ).resolves.toEqual({ merged: 1, conflicts: 0, failed: 0 });
  });
});
