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
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

// ── Hoisted mocks ────────────────────────────────────────────────────────────

const {
  mockEnsureBrInstalled,
  MockBeadsRustClient,
  MockBvClient,
  mockDispatch,
  MockDispatcher,
  mockGetActiveRuns,
  mockGetProjectByPath,
  mockGetRunsByStatuses,
  mockGetDb,
  MockForemanStore,
  mockWatchRunsInk,
  mockMergeQueueReconcile,
  mockMergeQueueDequeue,
  mockMergeQueueUpdateStatus,
  MockMergeQueue,
  mockRefineryMergeCompleted,
  MockRefinery,
} = vi.hoisted(() => {
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
  const mockGetDb = vi.fn().mockReturnValue({});
  const MockForemanStore = vi.fn(function (this: Record<string, unknown>) {
    this.close = vi.fn();
    this.getActiveRuns = mockGetActiveRuns;
    this.getProjectByPath = mockGetProjectByPath;
    this.getRunsByStatuses = mockGetRunsByStatuses;
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
    mockEnsureBrInstalled,
    MockBeadsRustClient,
    MockBvClient,
    mockDispatch,
    MockDispatcher,
    mockGetActiveRuns,
    mockGetProjectByPath,
    mockGetRunsByStatuses,
    mockGetDb,
    MockForemanStore,
    mockWatchRunsInk,
    mockMergeQueueReconcile,
    mockMergeQueueDequeue,
    mockMergeQueueUpdateStatus,
    MockMergeQueue,
    mockRefineryMergeCompleted,
    MockRefinery,
  };
});

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

import { runCommand, autoMerge, type AutoMergeOpts } from "../commands/run.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

async function invokeRun(args: string[]): Promise<void> {
  await runCommand.parseAsync(args, { from: "user" });
}

function resetMocks(): void {
  vi.clearAllMocks();
  vi.spyOn(console, "log").mockImplementation(() => {});
  vi.spyOn(console, "error").mockImplementation(() => {});

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

    // First dispatch: 1 task dispatched
    // Second dispatch: nothing dispatched, no active agents -> exit
    mockDispatch
      .mockResolvedValueOnce({
        dispatched: [
          {
            seedId: "s-1", runId: "run-111", title: "Task 1",
            model: "claude-sonnet-4-6", worktreePath: "/tmp/wt",
            branchName: "foreman/s-1", runtime: "claude-code",
          },
        ],
        skipped: [],
        activeAgents: 1,
      })
      .mockResolvedValueOnce({ dispatched: [], skipped: [], activeAgents: 0 });

    await invokeRun([]);

    // MergeQueue.reconcile should have been called once (in autoMerge)
    expect(mockMergeQueueReconcile).toHaveBeenCalledOnce();
  });

  it("processes merge queue after waiting-for-active-agents watch completes", async () => {
    mockGetProjectByPath.mockReturnValue({ id: "p1", path: "/mock/project" });

    // First dispatch: nothing dispatched, 2 active agents
    // Second dispatch: nothing dispatched, 0 active agents -> exit
    mockDispatch
      .mockResolvedValueOnce({ dispatched: [], skipped: [], activeAgents: 2 })
      .mockResolvedValueOnce({ dispatched: [], skipped: [], activeAgents: 0 });

    mockGetActiveRuns.mockReturnValueOnce([
      { id: "run-aaa", status: "running" },
      { id: "run-bbb", status: "running" },
    ]);

    await invokeRun([]);

    expect(mockMergeQueueReconcile).toHaveBeenCalledOnce();
  });

  it("does NOT process merge queue when --no-auto-merge is set", async () => {
    mockDispatch
      .mockResolvedValueOnce({
        dispatched: [
          {
            seedId: "s-2", runId: "run-222", title: "Task 2",
            model: "claude-sonnet-4-6", worktreePath: "/tmp/wt",
            branchName: "foreman/s-2", runtime: "claude-code",
          },
        ],
        skipped: [],
        activeAgents: 1,
      })
      .mockResolvedValueOnce({ dispatched: [], skipped: [], activeAgents: 0 });

    await invokeRun(["--no-auto-merge"]);

    expect(mockMergeQueueReconcile).not.toHaveBeenCalled();
    expect(MockMergeQueue).not.toHaveBeenCalled();
  });

  it("continues dispatch loop even when autoMerge internals throw (non-fatal)", async () => {
    mockGetProjectByPath.mockReturnValue({ id: "p1", path: "/mock/project" });
    // Make reconcile throw to simulate a broken merge system
    mockMergeQueueReconcile.mockRejectedValueOnce(new Error("merge system down"));

    mockDispatch
      .mockResolvedValueOnce({
        dispatched: [
          {
            seedId: "s-3", runId: "run-333", title: "Task 3",
            model: "claude-sonnet-4-6", worktreePath: "/tmp/wt",
            branchName: "foreman/s-3", runtime: "claude-code",
          },
        ],
        skipped: [],
        activeAgents: 1,
      })
      .mockResolvedValueOnce({ dispatched: [], skipped: [], activeAgents: 0 });

    // Should not throw — auto-merge errors are non-fatal
    await expect(invokeRun([])).resolves.toBeUndefined();

    // dispatch should be called twice: the initial batch + the re-check after auto-merge error
    expect(mockDispatch).toHaveBeenCalledTimes(2);
  });

  it("does NOT process merge queue in --dry-run mode", async () => {
    mockDispatch.mockResolvedValue({ dispatched: [], skipped: [], activeAgents: 0 });

    await invokeRun(["--dry-run"]);

    expect(MockMergeQueue).not.toHaveBeenCalled();
    expect(mockMergeQueueReconcile).not.toHaveBeenCalled();
  });

  it("does NOT process merge queue when user detaches (Ctrl+C) during watch", async () => {
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

    // autoMerge code is after the detach check — should NOT run
    expect(mockMergeQueueReconcile).not.toHaveBeenCalled();
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

    mockDispatch
      .mockResolvedValueOnce({
        dispatched: [
          {
            seedId: "sx", runId: "run-x", title: "Task X",
            model: "claude-sonnet-4-6", worktreePath: "/tmp/wt",
            branchName: "foreman/sx", runtime: "claude-code",
          },
        ],
        skipped: [],
        activeAgents: 1,
      })
      .mockResolvedValueOnce({ dispatched: [], skipped: [], activeAgents: 0 });

    await invokeRun([]);

    const logCalls = consoleSpy.mock.calls.map((c) => String(c[0]));
    const hasAutoMergeHeader = logCalls.some((m) => m.includes("Auto-merging completed branches"));
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
      .mockReturnValueOnce(fakeEntry)
      .mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValue({
      merged: [],
      conflicts: [{ runId: "ry", seedId: "sy", branchName: "foreman/sy", conflictFiles: ["x.ts"] }],
      testFailures: [],
      prsCreated: [],
    });

    mockDispatch
      .mockResolvedValueOnce({
        dispatched: [
          {
            seedId: "sy", runId: "run-y", title: "Task Y",
            model: "claude-sonnet-4-6", worktreePath: "/tmp/wt",
            branchName: "foreman/sy", runtime: "claude-code",
          },
        ],
        skipped: [],
        activeAgents: 1,
      })
      .mockResolvedValueOnce({ dispatched: [], skipped: [], activeAgents: 0 });

    await invokeRun([]);

    const logCalls = consoleSpy.mock.calls.map((c) => String(c[0]));
    const hasConflictLog = logCalls.some((m) => m.includes("conflict(s)"));

    expect(hasConflictLog).toBe(true);

    consoleSpy.mockRestore();
  });
});
