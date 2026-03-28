/**
 * Tests for mail notifications in src/orchestrator/auto-merge.ts
 *
 * Verifies that autoMerge() sends the correct mail messages for each
 * merge lifecycle event:
 *   - merge-complete  — branch merged successfully
 *   - merge-conflict  — conflict detected (code conflicts or PRs created)
 *   - merge-failed    — merge failed (test failures, no-completed-run, unexpected error)
 *   - bead-closed     — bead status synced in br after merge outcome
 *
 * These tests use a mock store.sendMessage() to capture sent messages
 * without requiring a real SQLite database.
 */

import { describe, it, expect, vi, beforeEach } from "vitest";

// ── Hoisted mocks ────────────────────────────────────────────────────────────

const {
  mockExecFileSync,
  mockGetProjectByPath,
  mockGetDb,
  mockGetRun,
  mockSendMessage,
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
  const mockSendMessage = vi.fn().mockReturnValue({ id: "msg-1" });

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
    mockSendMessage,
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

vi.mock("../../lib/store.js", () => ({
  ForemanStore: vi.fn(function (this: Record<string, unknown>) {
    this.close = vi.fn();
    this.getProjectByPath = mockGetProjectByPath;
    this.getDb = mockGetDb;
    this.getRun = mockGetRun;
    this.sendMessage = mockSendMessage;
    this.getRunsByStatuses = vi.fn().mockReturnValue([]);
  }),
}));

vi.mock("../task-backend-ops.js", () => ({
  enqueueAddNotesToBead: vi.fn(),
  enqueueMarkBeadFailed: vi.fn(),
  enqueueSetBeadStatus: vi.fn(),
}));

vi.mock("../merge-queue.js", () => ({
  MergeQueue: MockMergeQueue,
  RETRY_CONFIG: { maxRetries: 3, initialDelayMs: 60_000, maxDelayMs: 3_600_000, backoffMultiplier: 2 },
}));
vi.mock("../refinery.js", () => ({ Refinery: MockRefinery }));
vi.mock("../../lib/git.js", () => ({
  detectDefaultBranch: mockDetectDefaultBranch,
}));

import { autoMerge, type AutoMergeOpts } from "../auto-merge.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeStore(): {
  close: ReturnType<typeof vi.fn>;
  getProjectByPath: ReturnType<typeof vi.fn>;
  getDb: ReturnType<typeof vi.fn>;
  getRun: ReturnType<typeof vi.fn>;
  sendMessage: ReturnType<typeof vi.fn>;
  getRunsByStatuses: ReturnType<typeof vi.fn>;
} {
  return {
    close: vi.fn(),
    getProjectByPath: mockGetProjectByPath,
    getDb: mockGetDb,
    getRun: mockGetRun,
    sendMessage: mockSendMessage,
    getRunsByStatuses: vi.fn().mockReturnValue([]),
  };
}

function makeTaskClient(): { update: ReturnType<typeof vi.fn> } {
  return { update: mockTaskClientUpdate };
}

function makeOpts(overrides: Partial<AutoMergeOpts> = {}): AutoMergeOpts {
  return {
    store: makeStore() as never,
    taskClient: makeTaskClient() as never,
    projectPath: "/mock/project",
    ...overrides,
  };
}

function makeEntry(id: number = 1, seedId: string = `bd-test-00${id}`) {
  return { id, seed_id: seedId, run_id: `run-00${id}` };
}

function resetMocks(): void {
  vi.clearAllMocks();
  vi.spyOn(console, "warn").mockImplementation(() => {});

  mockExecFileSync.mockReturnValue(Buffer.from(""));
  mockDetectDefaultBranch.mockResolvedValue("main");
  mockGetProjectByPath.mockReturnValue({ id: "proj-1", path: "/mock/project" });
  mockGetDb.mockReturnValue({});
  mockGetRun.mockReturnValue({ id: "run-001", status: "merged" });
  mockSendMessage.mockReturnValue({ id: "msg-1" });
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

// ── Tests: no project registered ─────────────────────────────────────────────

describe("autoMerge() mail — no project registered", () => {
  beforeEach(() => {
    resetMocks();
    mockGetProjectByPath.mockReturnValue(null);
  });

  it("does not send any mail when no project is registered", async () => {
    await autoMerge(makeOpts());
    expect(mockSendMessage).not.toHaveBeenCalled();
  });
});

// ── Tests: merge-complete mail ────────────────────────────────────────────────

describe("autoMerge() mail — merge-complete", () => {
  beforeEach(resetMocks);

  it("sends merge-complete mail when a run is successfully merged", async () => {
    mockMergeQueueDequeue.mockReturnValueOnce(makeEntry(1)).mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValueOnce({
      merged: [{ runId: "run-001", seedId: "bd-test-001", branchName: "foreman/bd-test-001" }],
      conflicts: [],
      testFailures: [],
      prsCreated: [],
    });

    await autoMerge(makeOpts());

    const mergeCompleteCalls = mockSendMessage.mock.calls.filter(
      (c: unknown[]) => c[3] === "merge-complete",
    );
    expect(mergeCompleteCalls).toHaveLength(1);
    const [runId, sender, recipient, subject, bodyStr] = mergeCompleteCalls[0] as [string, string, string, string, string];
    expect(runId).toBe("run-001");
    expect(sender).toBe("auto-merge");
    expect(recipient).toBe("foreman");
    expect(subject).toBe("merge-complete");
    const body = JSON.parse(bodyStr) as Record<string, unknown>;
    expect(body.seedId).toBe("bd-test-001");
    expect(body.branchName).toBe("foreman/bd-test-001");
    expect(body.targetBranch).toBe("main");
    expect(body.timestamp).toBeDefined();
  });

  it("sends one merge-complete mail per merged run", async () => {
    mockMergeQueueDequeue.mockReturnValueOnce(makeEntry(1)).mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValueOnce({
      merged: [
        { runId: "run-001", seedId: "bd-test-001", branchName: "foreman/bd-test-001" },
        { runId: "run-002", seedId: "bd-test-002", branchName: "foreman/bd-test-002" },
      ],
      conflicts: [],
      testFailures: [],
      prsCreated: [],
    });

    await autoMerge(makeOpts());

    const mergeCompleteCalls = mockSendMessage.mock.calls.filter(
      (c: unknown[]) => c[3] === "merge-complete",
    );
    expect(mergeCompleteCalls).toHaveLength(2);
  });
});

// ── Tests: merge-conflict mail ────────────────────────────────────────────────

describe("autoMerge() mail — merge-conflict", () => {
  beforeEach(resetMocks);

  it("sends merge-conflict mail when code conflicts are detected", async () => {
    mockMergeQueueDequeue.mockReturnValueOnce(makeEntry(1)).mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValueOnce({
      merged: [],
      conflicts: [{ runId: "run-001", seedId: "bd-test-001", branchName: "foreman/bd-test-001", conflictFiles: ["src/foo.ts"] }],
      testFailures: [],
      prsCreated: [],
    });

    await autoMerge(makeOpts());

    const conflictCalls = mockSendMessage.mock.calls.filter(
      (c: unknown[]) => c[3] === "merge-conflict",
    );
    expect(conflictCalls).toHaveLength(1);
    const [runId, sender, recipient, subject, bodyStr] = conflictCalls[0] as [string, string, string, string, string];
    expect(runId).toBe("run-001");
    expect(sender).toBe("auto-merge");
    expect(recipient).toBe("foreman");
    expect(subject).toBe("merge-conflict");
    const body = JSON.parse(bodyStr) as Record<string, unknown>;
    expect(body.seedId).toBe("bd-test-001");
    expect(body.conflictFiles).toEqual(["src/foo.ts"]);
    expect(body.prCreated).toBe(false);
    expect(body.timestamp).toBeDefined();
  });

  it("sends merge-conflict mail with prCreated:true when a PR was created", async () => {
    mockMergeQueueDequeue.mockReturnValueOnce(makeEntry(1)).mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValueOnce({
      merged: [],
      conflicts: [],
      testFailures: [],
      prsCreated: [{ runId: "run-001", seedId: "bd-test-001", branchName: "foreman/bd-test-001", prUrl: "https://github.com/x/y/pull/42" }],
    });

    await autoMerge(makeOpts());

    const conflictCalls = mockSendMessage.mock.calls.filter(
      (c: unknown[]) => c[3] === "merge-conflict",
    );
    expect(conflictCalls).toHaveLength(1);
    const body = JSON.parse(conflictCalls[0][4] as string) as Record<string, unknown>;
    expect(body.prCreated).toBe(true);
    expect(body.prUrl).toBe("https://github.com/x/y/pull/42");
  });

  it("sends merge-conflict for both conflict runs and PRs created", async () => {
    mockMergeQueueDequeue.mockReturnValueOnce(makeEntry(1)).mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValueOnce({
      merged: [],
      conflicts: [{ runId: "run-001", seedId: "bd-test-001", branchName: "foreman/bd-test-001", conflictFiles: [] }],
      testFailures: [],
      prsCreated: [{ runId: "run-002", seedId: "bd-test-002", branchName: "foreman/bd-test-002", prUrl: "https://github.com/x/y/pull/43" }],
    });

    await autoMerge(makeOpts());

    const conflictCalls = mockSendMessage.mock.calls.filter(
      (c: unknown[]) => c[3] === "merge-conflict",
    );
    expect(conflictCalls).toHaveLength(2);
  });
});

// ── Tests: merge-failed mail ──────────────────────────────────────────────────

describe("autoMerge() mail — merge-failed (test failures)", () => {
  beforeEach(resetMocks);

  it("sends merge-failed mail when test failures are reported", async () => {
    mockMergeQueueDequeue.mockReturnValueOnce(makeEntry(1)).mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValueOnce({
      merged: [],
      conflicts: [],
      testFailures: [{ runId: "run-001", seedId: "bd-test-001", branchName: "foreman/bd-test-001", error: "Tests failed: 3 failures" }],
      prsCreated: [],
    });

    await autoMerge(makeOpts());

    const failedCalls = mockSendMessage.mock.calls.filter(
      (c: unknown[]) => c[3] === "merge-failed",
    );
    expect(failedCalls).toHaveLength(1);
    const [runId, sender, recipient, subject, bodyStr] = failedCalls[0] as [string, string, string, string, string];
    expect(runId).toBe("run-001");
    expect(sender).toBe("auto-merge");
    expect(recipient).toBe("foreman");
    expect(subject).toBe("merge-failed");
    const body = JSON.parse(bodyStr) as Record<string, unknown>;
    expect(body.seedId).toBe("bd-test-001");
    expect(body.reason).toBe("test-failure");
    expect(body.error).toBe("Tests failed: 3 failures");
    expect(body.timestamp).toBeDefined();
  });
});

describe("autoMerge() mail — merge-failed (no completed run)", () => {
  beforeEach(resetMocks);

  it("sends merge-failed with reason no-completed-run when all report arrays are empty", async () => {
    mockMergeQueueDequeue.mockReturnValueOnce(makeEntry(1)).mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValueOnce({
      merged: [],
      conflicts: [],
      testFailures: [],
      prsCreated: [],
    });

    await autoMerge(makeOpts());

    const failedCalls = mockSendMessage.mock.calls.filter(
      (c: unknown[]) => c[3] === "merge-failed",
    );
    expect(failedCalls).toHaveLength(1);
    const body = JSON.parse(failedCalls[0][4] as string) as Record<string, unknown>;
    expect(body.seedId).toBe("bd-test-001");
    expect(body.reason).toBe("no-completed-run");
    expect(body.timestamp).toBeDefined();
  });
});

describe("autoMerge() mail — merge-failed (unexpected error)", () => {
  beforeEach(resetMocks);

  it("sends merge-failed with reason unexpected-error when refinery throws", async () => {
    mockMergeQueueDequeue
      .mockReturnValueOnce(makeEntry(1, "bd-err-001"))
      .mockReturnValue(null);
    mockRefineryMergeCompleted.mockRejectedValueOnce(new Error("git rebase failed: conflict"));

    await autoMerge(makeOpts());

    const failedCalls = mockSendMessage.mock.calls.filter(
      (c: unknown[]) => c[3] === "merge-failed",
    );
    expect(failedCalls).toHaveLength(1);
    const [runId, sender, , subject, bodyStr] = failedCalls[0] as [string, string, string, string, string];
    expect(runId).toBe("run-001");
    expect(sender).toBe("auto-merge");
    expect(subject).toBe("merge-failed");
    const body = JSON.parse(bodyStr) as Record<string, unknown>;
    expect(body.seedId).toBe("bd-err-001");
    expect(body.reason).toBe("unexpected-error");
    expect(body.error).toBe("git rebase failed: conflict");
    expect(body.timestamp).toBeDefined();
  });

  it("truncates long error messages to 400 chars", async () => {
    const longError = "x".repeat(500);
    mockMergeQueueDequeue
      .mockReturnValueOnce(makeEntry(1))
      .mockReturnValue(null);
    mockRefineryMergeCompleted.mockRejectedValueOnce(new Error(longError));

    await autoMerge(makeOpts());

    const failedCalls = mockSendMessage.mock.calls.filter(
      (c: unknown[]) => c[3] === "merge-failed",
    );
    const body = JSON.parse(failedCalls[0][4] as string) as Record<string, unknown>;
    expect((body.error as string).length).toBeLessThanOrEqual(400);
  });
});

// ── Tests: bead-closed mail ───────────────────────────────────────────────────

describe("autoMerge() mail — bead-closed", () => {
  beforeEach(resetMocks);

  it("sends bead-closed mail after successful merge", async () => {
    mockMergeQueueDequeue.mockReturnValueOnce(makeEntry(1)).mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValueOnce({
      merged: [{ runId: "run-001", seedId: "bd-test-001", branchName: "foreman/bd-test-001" }],
      conflicts: [],
      testFailures: [],
      prsCreated: [],
    });

    await autoMerge(makeOpts());

    const beadClosedCalls = mockSendMessage.mock.calls.filter(
      (c: unknown[]) => c[3] === "bead-closed",
    );
    expect(beadClosedCalls).toHaveLength(1);
    const [runId, sender, recipient, subject, bodyStr] = beadClosedCalls[0] as [string, string, string, string, string];
    expect(runId).toBe("run-001");
    expect(sender).toBe("auto-merge");
    expect(recipient).toBe("foreman");
    expect(subject).toBe("bead-closed");
    const body = JSON.parse(bodyStr) as Record<string, unknown>;
    expect(body.seedId).toBe("bd-test-001");
    expect(body.timestamp).toBeDefined();
  });

  it("sends bead-closed mail even when merge fails (after conflict)", async () => {
    mockMergeQueueDequeue.mockReturnValueOnce(makeEntry(1)).mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValueOnce({
      merged: [],
      conflicts: [{ runId: "run-001", seedId: "bd-test-001", branchName: "foreman/bd-test-001", conflictFiles: [] }],
      testFailures: [],
      prsCreated: [],
    });

    await autoMerge(makeOpts());

    const beadClosedCalls = mockSendMessage.mock.calls.filter(
      (c: unknown[]) => c[3] === "bead-closed",
    );
    expect(beadClosedCalls).toHaveLength(1);
    expect(beadClosedCalls[0][0]).toBe("run-001");
  });

  it("sends bead-closed mail even when refinery throws", async () => {
    mockMergeQueueDequeue
      .mockReturnValueOnce(makeEntry(1))
      .mockReturnValue(null);
    mockRefineryMergeCompleted.mockRejectedValueOnce(new Error("unexpected"));

    await autoMerge(makeOpts());

    const beadClosedCalls = mockSendMessage.mock.calls.filter(
      (c: unknown[]) => c[3] === "bead-closed",
    );
    expect(beadClosedCalls).toHaveLength(1);
  });
});

// ── Tests: mail is non-fatal ──────────────────────────────────────────────────

describe("autoMerge() mail — non-fatal", () => {
  beforeEach(resetMocks);

  it("does not throw when store.sendMessage() throws", async () => {
    mockGetProjectByPath.mockReturnValue({ id: "proj-1" });
    mockMergeQueueDequeue.mockReturnValueOnce(makeEntry(1)).mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValueOnce({
      merged: [{ runId: "run-001", seedId: "bd-test-001", branchName: "foreman/bd-test-001" }],
      conflicts: [],
      testFailures: [],
      prsCreated: [],
    });
    mockSendMessage.mockImplementation(() => { throw new Error("DB write failed"); });

    await expect(autoMerge(makeOpts())).resolves.not.toThrow();
  });

  it("returns correct counts even when sendMessage throws", async () => {
    mockGetProjectByPath.mockReturnValue({ id: "proj-1" });
    mockMergeQueueDequeue.mockReturnValueOnce(makeEntry(1)).mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValueOnce({
      merged: [{ runId: "run-001", seedId: "bd-test-001", branchName: "foreman/bd-test-001" }],
      conflicts: [],
      testFailures: [],
      prsCreated: [],
    });
    mockSendMessage.mockImplementation(() => { throw new Error("DB write failed"); });

    const result = await autoMerge(makeOpts());
    expect(result.merged).toBe(1);
  });
});

// ── Tests: correct run_id scoping ─────────────────────────────────────────────

describe("autoMerge() mail — run_id scoping", () => {
  beforeEach(resetMocks);

  it("uses currentEntry.run_id to scope all mail messages for that entry", async () => {
    const entry = { id: 42, seed_id: "bd-scope-001", run_id: "run-scope-xyz" };
    mockMergeQueueDequeue.mockReturnValueOnce(entry).mockReturnValue(null);
    mockRefineryMergeCompleted.mockResolvedValueOnce({
      merged: [],
      conflicts: [],
      testFailures: [],
      prsCreated: [],
    });

    await autoMerge(makeOpts());

    // All messages should use the entry's run_id
    for (const call of mockSendMessage.mock.calls as unknown[][]) {
      expect(call[0]).toBe("run-scope-xyz");
    }
  });

  it("scopes mail messages separately for each queue entry", async () => {
    mockMergeQueueDequeue
      .mockReturnValueOnce({ id: 1, seed_id: "bd-001", run_id: "run-aaa" })
      .mockReturnValueOnce({ id: 2, seed_id: "bd-002", run_id: "run-bbb" })
      .mockReturnValue(null);
    mockRefineryMergeCompleted
      .mockResolvedValueOnce({ merged: [{ runId: "run-aaa", seedId: "bd-001", branchName: "foreman/bd-001" }], conflicts: [], testFailures: [], prsCreated: [] })
      .mockResolvedValueOnce({ merged: [{ runId: "run-bbb", seedId: "bd-002", branchName: "foreman/bd-002" }], conflicts: [], testFailures: [], prsCreated: [] });

    await autoMerge(makeOpts());

    const allRunIds = (mockSendMessage.mock.calls as unknown[][]).map((c) => c[0] as string);
    expect(allRunIds).toContain("run-aaa");
    expect(allRunIds).toContain("run-bbb");
  });
});
