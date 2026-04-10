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
  mockGetRun,
  MockForemanStore,
  mockReconcile,
  mockList,
  mockDequeue,
  mockUpdateStatus,
  mockResetForRetry,
  mockGetRetryableEntries,
  mockReEnqueue,
  MockMergeQueue,
  mockResolveConflict,
  mockMergeCompleted,
  mockDryRunMerge,
  MockRefinery,
  mockSyncBeadStatusAfterMerge,
  mockGetResolutionRate,
  MockMergeCostTracker,
  mockResolveProjectBranchPolicy,
  mockLoadProjectConfig,
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
  const mockGetRun = vi.fn().mockReturnValue(null);
  const MockForemanStore = vi.fn(function MockForemanStoreImpl(this: Record<string, unknown>) {
    this.getProjectByPath = mockGetProjectByPath;
    this.getDb = mockGetDb;
    this.getRun = mockGetRun;
    this.close = mockStoreClose;
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (MockForemanStore as any).forProject = vi.fn(() => new (MockForemanStore as any)());

  const mockReconcile = vi.fn().mockResolvedValue({ enqueued: 0, failedToEnqueue: [] });
  const mockList = vi.fn().mockReturnValue([]);
  const mockDequeue = vi.fn().mockReturnValue(null);
  const mockUpdateStatus = vi.fn();
  const mockResetForRetry = vi.fn();
  const mockGetRetryableEntries = vi.fn().mockReturnValue([]);
  const mockReEnqueue = vi.fn().mockReturnValue(false);
  const MockMergeQueue = vi.fn(function MockMergeQueueImpl(this: Record<string, unknown>) {
    this.reconcile = mockReconcile;
    this.list = mockList;
    this.dequeue = mockDequeue;
    this.updateStatus = mockUpdateStatus;
    this.resetForRetry = mockResetForRetry;
    this.getRetryableEntries = mockGetRetryableEntries;
    this.reEnqueue = mockReEnqueue;
  });

  const mockResolveConflict = vi.fn().mockResolvedValue(true);
  const mockMergeCompleted = vi.fn().mockResolvedValue({
    merged: [],
    conflicts: [],
    testFailures: [],
    unexpectedErrors: [],
    prsCreated: [],
  });
  const mockDryRunMerge = vi.fn().mockResolvedValue([]);
  const MockRefinery = vi.fn(function MockRefineryImpl(this: Record<string, unknown>) {
    this.resolveConflict = mockResolveConflict;
    this.mergeCompleted = mockMergeCompleted;
  });

  const mockSyncBeadStatusAfterMerge = vi.fn().mockResolvedValue(undefined);

  const mockGetResolutionRate = vi.fn().mockReturnValue({ successes: 0, total: 0, rate: 0 });
  const MockMergeCostTracker = vi.fn(function MockMergeCostTrackerImpl(this: Record<string, unknown>) {
    this.getResolutionRate = mockGetResolutionRate;
  });

  const mockResolveProjectBranchPolicy = vi.fn().mockResolvedValue({ integrationBranch: "main" });
  const mockLoadProjectConfig = vi.fn().mockReturnValue(null);

  return {
    mockStartupVcs,
    mockMergeVcs,
    mockCreateVcs,
    mockEnsureBrInstalled,
    MockBeadsRustClient,
    mockStoreClose,
    mockGetProjectByPath,
    mockGetDb,
    mockGetRun,
    MockForemanStore,
    mockReconcile,
    mockList,
    mockDequeue,
    mockUpdateStatus,
    mockResetForRetry,
    mockGetRetryableEntries,
    mockReEnqueue,
    MockMergeQueue,
    mockResolveConflict,
    mockMergeCompleted,
    mockDryRunMerge,
    MockRefinery,
    mockSyncBeadStatusAfterMerge,
    mockGetResolutionRate,
    MockMergeCostTracker,
    mockResolveProjectBranchPolicy,
    mockLoadProjectConfig,
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
  dryRunMerge: (...args: unknown[]) => mockDryRunMerge(...args),
}));

vi.mock("../../orchestrator/auto-merge.js", () => ({
  syncBeadStatusAfterMerge: (...args: unknown[]) => mockSyncBeadStatusAfterMerge(...args),
}));

vi.mock("../../orchestrator/merge-cost-tracker.js", () => ({
  MergeCostTracker: MockMergeCostTracker,
}));

vi.mock("../../lib/project-config.js", () => ({
  loadProjectConfig: mockLoadProjectConfig,
  resolveVcsConfig: vi.fn().mockReturnValue({ backend: "auto" }),
}));

vi.mock("../../lib/branch-policy.js", () => ({
  resolveProjectBranchPolicy: mockResolveProjectBranchPolicy,
}));

vi.mock("../../lib/branch-names.js", () => ({
  getForemanBranchName: vi.fn((seedId: string) => `foreman/${seedId}`),
}));

import { mergeCommand } from "../commands/merge.js";

async function runCommand(args: string[]): Promise<{ stdout: string; stderr: string; error?: Error }> {
  const stdoutLines: string[] = [];
  const stderrLines: string[] = [];
  const origLog = console.log;
  const origWarn = console.warn;
  const origError = console.error;
  let error: Error | undefined;

  console.log = (...a: unknown[]) => stdoutLines.push(a.join(" "));
  console.warn = (...a: unknown[]) => stderrLines.push(a.join(" "));
  console.error = (...a: unknown[]) => stderrLines.push(a.join(" "));

  try {
    await mergeCommand.parseAsync(["node", "foreman", ...args]);
  } catch (caught) {
    error = caught as Error;
  } finally {
    console.log = origLog;
    console.warn = origWarn;
    console.error = origError;
  }

  return { stdout: stdoutLines.join("\n"), stderr: stderrLines.join("\n"), error };
}

describe("merge --json success contracts", () => {
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
    mockGetRun.mockReturnValue(null);
    mockReconcile.mockReset().mockResolvedValue({ enqueued: 0, failedToEnqueue: [] });
    mockList.mockReset().mockReturnValue([]);
    mockDequeue.mockReset().mockReturnValue(null);
    mockUpdateStatus.mockReset();
    mockResetForRetry.mockReset();
    mockGetRetryableEntries.mockReset().mockReturnValue([]);
    mockReEnqueue.mockReset().mockReturnValue(false);
    mockResolveConflict.mockReset().mockResolvedValue(true);
    mockMergeCompleted.mockReset().mockResolvedValue({
      merged: [],
      conflicts: [],
      testFailures: [],
      unexpectedErrors: [],
      prsCreated: [],
    });
    mockDryRunMerge.mockReset().mockResolvedValue([]);
    mockSyncBeadStatusAfterMerge.mockReset().mockResolvedValue(undefined);
    mockGetResolutionRate.mockReset().mockReturnValue({ successes: 0, total: 0, rate: 0 });
  });

  afterEach(() => {
    exitSpy.mockRestore();
  });

  it("emits pure JSON for successful --resolve --json", async () => {
    mockGetRun.mockReturnValue({
      id: "run-123",
      seed_id: "bd-123",
      status: "conflict",
    });
    mockResolveConflict.mockResolvedValue(true);

    const { stdout, stderr, error } = await runCommand(["--resolve", "run-123", "--strategy", "theirs", "--json"]);

    expect(error).toBeUndefined();
    expect(stderr).toBe("");
    expect(stdout).not.toContain("Resolving conflict for");
    expect(JSON.parse(stdout)).toEqual({
      runId: "run-123",
      seedId: "bd-123",
      branchName: "foreman/bd-123",
      strategy: "theirs",
      status: "merged",
    });
  });

  it("emits pure JSON for --dry-run --json", async () => {
    mockList.mockReturnValue([{ branch_name: "foreman/bd-dry", seed_id: "bd-dry" }]);
    mockDryRunMerge.mockResolvedValue([
      {
        seedId: "bd-dry",
        branchName: "foreman/bd-dry",
        diffStat: " src/file.ts | 2 +-",
        hasConflicts: false,
        estimatedTier: 2,
      },
    ]);

    const { stdout, stderr, error } = await runCommand(["--dry-run", "--json"]);

    expect(error).toBeUndefined();
    expect(stderr).toBe("");
    expect(stdout).not.toContain("Dry-run merge preview");

    const data = JSON.parse(stdout);
    expect(data).toEqual({
      targetBranch: "main",
      bead: null,
      reconciled: 0,
      results: [
        {
          seedId: "bd-dry",
          branchName: "foreman/bd-dry",
          diffStat: " src/file.ts | 2 +-",
          hasConflicts: false,
          estimatedTier: 2,
        },
      ],
      warnings: [],
    });
  });

  it("emits machine-readable warnings and summary for default --json flow", async () => {
    mockReconcile
      .mockResolvedValueOnce({
        enqueued: 1,
        failedToEnqueue: [{ seed_id: "bd-missing", reason: "branch missing" }],
      })
      .mockRejectedValueOnce(new Error("refresh failed"));
    mockDequeue
      .mockReturnValueOnce({
        id: 7,
        seed_id: "bd-merge",
        run_id: "run-merge",
        branch_name: "foreman/bd-merge",
      })
      .mockReturnValueOnce(null);
    mockMergeCompleted.mockResolvedValue({
      merged: [
        {
          runId: "run-merge",
          seedId: "bd-merge",
          branchName: "foreman/bd-merge",
          resolvedTiers: new Map([["src/foo.ts", 3]]),
        },
      ],
      conflicts: [],
      testFailures: [],
      unexpectedErrors: [],
      prsCreated: [],
    });
    mockGetResolutionRate.mockReturnValue({ successes: 2, total: 5, rate: 40 });

    const { stdout, stderr, error } = await runCommand(["--json"]);

    expect(error).toBeUndefined();
    expect(stdout).not.toContain("Running refinery on completed work");
    expect(stdout).not.toContain("Processing:");
    expect(stderr).toContain("completed run(s) could not be enqueued");
    expect(stderr).toContain("Mid-loop reconcile failed (refresh failed)");

    const data = JSON.parse(stdout);
    expect(data.summary).toEqual({
      initialReconciled: 1,
      additionalReconciled: 0,
      retried: 0,
      merged: 1,
      conflicts: 0,
      prsCreated: 0,
      testFailures: 0,
      unexpectedErrors: 0,
      missingCompletedRuns: 0,
    });
    expect(data.failedToEnqueue).toEqual([
      { seed_id: "bd-missing", reason: "branch missing" },
    ]);
    expect(data.merged).toEqual([
      {
        runId: "run-merge",
        seedId: "bd-merge",
        branchName: "foreman/bd-merge",
        resolvedTiers: {
          "src/foo.ts": 3,
        },
      },
    ]);
    expect(data.warnings).toEqual([
      "Warning: 1 completed run(s) could not be enqueued (branch missing).",
      "Mid-loop reconcile failed (refresh failed); continuing with existing queue entries.",
    ]);
    expect(data.resolutionRate30d).toEqual({
      successes: 2,
      total: 5,
      rate: 40,
    });
  });
});
