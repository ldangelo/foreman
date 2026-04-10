import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

let exitSpy: ReturnType<typeof vi.spyOn>;

const {
  mockStartupVcs,
  mockMergeVcs,
  mockCreateVcs,
  mockEnsureBrInstalled,
  MockBeadsRustClient,
  mockStoreClose,
  mockGetProjectByPath,
  mockGetDb,
  MockForemanStore,
  mockReconcile,
  mockDequeue,
  mockUpdateStatus,
  MockMergeQueue,
  mockMergeCompleted,
  MockRefinery,
  mockSyncBeadStatusAfterMerge,
} = vi.hoisted(() => {
  const mockStartupVcs = {
    getRepoRoot: vi.fn().mockResolvedValue("/mock/project"),
  };

  const mockMergeVcs = {
    name: "jujutsu",
    detectDefaultBranch: vi.fn().mockResolvedValue("main"),
  };

  const mockCreateVcs = vi
    .fn()
    .mockResolvedValueOnce(mockStartupVcs)
    .mockResolvedValue(mockMergeVcs);

  const mockEnsureBrInstalled = vi.fn().mockResolvedValue(undefined);
  const MockBeadsRustClient = vi.fn(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
    this.ensureBrInstalled = mockEnsureBrInstalled;
  });

  const mockStoreClose = vi.fn();
  const mockGetProjectByPath = vi.fn().mockReturnValue({ id: "proj-1", path: "/mock/project" });
  const mockGetDb = vi.fn().mockReturnValue({});
  const MockForemanStore = vi.fn(function MockForemanStoreImpl(this: Record<string, unknown>) {
    this.getProjectByPath = mockGetProjectByPath;
    this.getDb = mockGetDb;
    this.close = mockStoreClose;
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (MockForemanStore as any).forProject = vi.fn(() => new (MockForemanStore as any)());

  const mockReconcile = vi.fn().mockResolvedValue({ enqueued: 0, failedToEnqueue: [] });
  const mockDequeue = vi
    .fn()
    .mockReturnValueOnce({
      id: 1,
      seed_id: "bd-123",
      run_id: "run-123",
      branch_name: "foreman/bd-123",
      status: "pending",
      agent_name: null,
      files_modified: [],
      enqueued_at: new Date().toISOString(),
      started_at: null,
      completed_at: null,
      resolved_tier: null,
      error: null,
      retry_count: 0,
      next_retry_at: null,
    })
    .mockReturnValue(null);
  const mockUpdateStatus = vi.fn();
  const MockMergeQueue = vi.fn(function MockMergeQueueImpl(this: Record<string, unknown>) {
    this.reconcile = mockReconcile;
    this.dequeue = mockDequeue;
    this.updateStatus = mockUpdateStatus;
    this.resetForRetry = vi.fn();
    this.getRetryableEntries = vi.fn().mockReturnValue([]);
    this.list = vi.fn().mockReturnValue([]);
  });

  const mockMergeCompleted = vi.fn().mockResolvedValue({
    merged: [],
    conflicts: [],
    testFailures: [],
    unexpectedErrors: [
      {
        runId: "run-123",
        seedId: "bd-123",
        branchName: "foreman/bd-123",
        error: "jj rebase failed unexpectedly",
      },
    ],
    prsCreated: [],
  });
  const MockRefinery = vi.fn(function MockRefineryImpl(this: Record<string, unknown>) {
    this.mergeCompleted = mockMergeCompleted;
  });

  const mockSyncBeadStatusAfterMerge = vi.fn().mockResolvedValue(undefined);

  return {
    mockStartupVcs,
    mockMergeVcs,
    mockCreateVcs,
    mockEnsureBrInstalled,
    MockBeadsRustClient,
    mockStoreClose,
    mockGetProjectByPath,
    mockGetDb,
    MockForemanStore,
    mockReconcile,
    mockDequeue,
    mockUpdateStatus,
    MockMergeQueue,
    mockMergeCompleted,
    MockRefinery,
    mockSyncBeadStatusAfterMerge,
  };
});

vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: (...args: unknown[]) => mockCreateVcs(...args),
  },
}));

vi.mock("../../lib/beads-rust.js", () => ({
  BeadsRustClient: MockBeadsRustClient,
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: MockForemanStore,
}));

vi.mock("../../orchestrator/merge-queue.js", () => ({
  MergeQueue: MockMergeQueue,
}));

vi.mock("../../orchestrator/refinery.js", () => ({
  Refinery: MockRefinery,
  dryRunMerge: vi.fn(),
}));

vi.mock("../../orchestrator/auto-merge.js", () => ({
  syncBeadStatusAfterMerge: mockSyncBeadStatusAfterMerge,
}));

vi.mock("../../orchestrator/merge-cost-tracker.js", () => ({
  MergeCostTracker: vi.fn(function MockMergeCostTrackerImpl(this: Record<string, unknown>) {
    this.getStats = vi.fn();
    this.getResolutionRate = vi.fn().mockReturnValue({ total: 0, successes: 0, rate: 0 });
  }),
}));

import { mergeCommand } from "../commands/merge.js";

async function runCommand(args: string[]): Promise<{ stdout: string; stderr: string }> {
  const stdoutLines: string[] = [];
  const stderrLines: string[] = [];
  const origLog = console.log;
  const origWarn = console.warn;
  const origError = console.error;

  console.log = (...a: unknown[]) => stdoutLines.push(a.join(" "));
  console.warn = (...a: unknown[]) => stderrLines.push(a.join(" "));
  console.error = (...a: unknown[]) => stderrLines.push(a.join(" "));

  try {
    await mergeCommand.parseAsync(["node", "foreman", ...args]);
  } finally {
    console.log = origLog;
    console.warn = origWarn;
    console.error = origError;
  }

  return { stdout: stdoutLines.join("\n"), stderr: stderrLines.join("\n") };
}

describe("merge command", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    exitSpy = vi.spyOn(process, "exit").mockImplementation((code?: number | string | null | undefined) => {
      throw new Error(`process.exit unexpectedly called with ${JSON.stringify(code ?? "")}`);
    });
    mockCreateVcs.mockReset();
    mockCreateVcs
      .mockResolvedValueOnce(mockStartupVcs)
      .mockResolvedValue(mockMergeVcs);
    mockGetProjectByPath.mockReturnValue({ id: "proj-1", path: "/mock/project" });
    mockReconcile.mockResolvedValue({ enqueued: 0, failedToEnqueue: [] });
    mockDequeue.mockReset();
    mockDequeue
      .mockReturnValueOnce({
        id: 1,
        seed_id: "bd-123",
        run_id: "run-123",
        branch_name: "foreman/bd-123",
        status: "pending",
        agent_name: null,
        files_modified: [],
        enqueued_at: new Date().toISOString(),
        started_at: null,
        completed_at: null,
        resolved_tier: null,
        error: null,
        retry_count: 0,
        next_retry_at: null,
      })
      .mockReturnValue(null);
    mockMergeCompleted.mockResolvedValue({
      merged: [],
      conflicts: [],
      testFailures: [],
      unexpectedErrors: [
        {
          runId: "run-123",
          seedId: "bd-123",
          branchName: "foreman/bd-123",
          error: "jj rebase failed unexpectedly",
        },
      ],
      prsCreated: [],
    });
  });

  afterEach(() => {
    exitSpy.mockRestore();
  });

  it("passes the resolved VCS backend into Refinery", async () => {
    await runCommand([]);

    expect(MockRefinery).toHaveBeenCalledWith(
      expect.any(Object),
      expect.any(Object),
      "/mock/project",
      mockMergeVcs,
    );
  });

  it("surfaces unexpected merge errors distinctly", async () => {
    const { stdout } = await runCommand([]);

    expect(stdout).toContain("Unexpected merge errors in 1 task(s)");
    expect(stdout).toContain("bd-123 foreman/bd-123");
    expect(stdout).toContain("jj rebase failed unexpectedly");
    expect(mockUpdateStatus).toHaveBeenCalledWith(1, "failed", { error: "Unexpected merge errors" });
  });
});
