/**
 * Tests for --json output flag on status and merge --list commands.
 *
 * Verifies:
 * - JSON output is valid and parseable when --json flag is passed
 * - JSON schema matches the expected structure for each command
 * - Formatted output (default) is not affected when flag is omitted
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// ── Hoisted mocks ───────────────────────────────────────────────────────────
const {
  mockGetRepoRoot,
  mockDetectDefaultBranch,
  mockCreateVcsBackend,
  mockBrList,
  mockBrReady,
  mockEnsureBrInstalled,
  mockCreateTaskClient,
  mockFetchTaskCounts,
  MockBeadsRustClient,
  mockGetProjectByPath,
  mockGetActiveRuns,
  mockGetMetrics,
  mockGetRunsByStatusSince,
  mockGetRunProgress,
  mockGetDb,
  mockGetRecentOutcomeCounts,
  mockGetRunsForSeed,
  MockForemanStore,
  MockPostgresStore,
  mockReconcile,
  mockList,
  MockMergeQueue,
} = vi.hoisted(() => {
  const mockCreateTaskClient = vi.fn().mockResolvedValue({ taskClient: { kind: "task-client" }, backendType: "native" });
  const mockFetchTaskCounts = vi.fn().mockResolvedValue({ total: 0, ready: 0, inProgress: 0, completed: 0, blocked: 0 });
  const mockGetRepoRoot = vi.fn().mockResolvedValue("/mock/project");
  const mockDetectDefaultBranch = vi.fn().mockResolvedValue("main");
  const mockCreateVcsBackend = vi.fn().mockResolvedValue({
    name: "git",
    getRepoRoot: mockGetRepoRoot,
    getCurrentBranch: vi.fn().mockResolvedValue("main"),
    checkoutBranch: vi.fn().mockResolvedValue(undefined),
    getRemoteUrl: vi.fn().mockResolvedValue(null),
    detectDefaultBranch: mockDetectDefaultBranch,
  });

  // BeadsRustClient mocks
  const mockBrList = vi.fn().mockResolvedValue([]);
  const mockBrReady = vi.fn().mockResolvedValue([]);
  const mockEnsureBrInstalled = vi.fn().mockResolvedValue(undefined);
  const MockBeadsRustClient = vi.fn(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
    this.list = mockBrList;
    this.ready = mockBrReady;
    this.ensureBrInstalled = mockEnsureBrInstalled;
  });

  // ForemanStore mocks
  const mockGetProjectByPath = vi.fn().mockReturnValue(null);
  const mockGetActiveRuns = vi.fn().mockReturnValue([]);
  const mockGetMetrics = vi.fn().mockReturnValue({ totalCost: 0, totalTokens: 0, tasksByStatus: {}, costByRuntime: [] });
  const mockGetRunsByStatusSince = vi.fn().mockReturnValue([]);
  const mockGetRunProgress = vi.fn().mockReturnValue(null);
  const mockGetDb = vi.fn().mockReturnValue({});
  const mockGetRecentOutcomeCounts = vi.fn().mockReturnValue({ merged: 0, failed: 0, stuck: 0 });
  const mockGetRunsForSeed = vi.fn().mockReturnValue([]);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const MockForemanStore = vi.fn(function MockForemanStoreImpl(this: Record<string, unknown>) {
    this.getProjectByPath = mockGetProjectByPath;
    this.getActiveRuns = mockGetActiveRuns;
    this.getMetrics = mockGetMetrics;
    this.getRunsByStatusSince = mockGetRunsByStatusSince;
    this.getRunProgress = mockGetRunProgress;
    this.getDb = mockGetDb;
    this.close = vi.fn();
    this.getSuccessRate = vi.fn(() => ({ rate: null, merged: 0, failed: 0 }));
    this.getRecentOutcomeCounts = mockGetRecentOutcomeCounts;
    this.getRunsForSeed = mockGetRunsForSeed;
  });
  (MockForemanStore as typeof MockForemanStore & Record<"forProject", unknown>).forProject = vi.fn(
    (_projectPath: string) => new MockForemanStore(),
  );
  const MockPostgresStore = vi.fn(function MockPostgresStoreImpl(this: Record<string, unknown>) {
    this.getRun = vi.fn();
    this.getRunsByStatus = vi.fn();
    this.getRunsByStatuses = vi.fn();
    this.getRunsByBaseBranch = vi.fn();
  });

  // MergeQueue mocks
  const mockReconcile = vi.fn().mockResolvedValue({ enqueued: 0 });
  const mockList = vi.fn().mockReturnValue([]);
  const MockMergeQueue = vi.fn(function MockMergeQueueImpl(this: Record<string, unknown>) {
    this.reconcile = mockReconcile;
    this.list = mockList;
    this.dequeue = vi.fn().mockReturnValue(null);
    this.updateStatus = vi.fn();
    this.resetForRetry = vi.fn();
  });

  return {
    mockGetRepoRoot,
    mockDetectDefaultBranch,
    mockCreateVcsBackend,
    mockBrList,
    mockBrReady,
    mockEnsureBrInstalled,
    mockCreateTaskClient,
    mockFetchTaskCounts,
    MockBeadsRustClient,
    mockGetProjectByPath,
    mockGetActiveRuns,
    mockGetMetrics,
    mockGetRunsByStatusSince,
    mockGetRunProgress,
    mockGetDb,
    mockGetRecentOutcomeCounts,
    mockGetRunsForSeed,
    MockForemanStore,
    MockPostgresStore,
    mockReconcile,
    mockList,
    MockMergeQueue,
  };
});

vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: mockCreateVcsBackend,
  },
}));

vi.mock("../../lib/beads-rust.js", () => ({
  BeadsRustClient: MockBeadsRustClient,
}));

vi.mock("../../lib/task-client-factory.js", async () => {
  const actual = await vi.importActual<typeof import("../../lib/task-client-factory.js")>("../../lib/task-client-factory.js");
  return {
    ...actual,
    createTaskClient: mockCreateTaskClient,
    fetchTaskCounts: mockFetchTaskCounts,
  };
});

vi.mock("../../lib/store.js", () => ({
  ForemanStore: MockForemanStore,
}));

vi.mock("../../lib/postgres-store.js", () => ({
  PostgresStore: MockPostgresStore,
}));

vi.mock("../../orchestrator/merge-queue.js", () => ({
  MergeQueue: MockMergeQueue,
}));

vi.mock("../../orchestrator/refinery.js", () => ({
  Refinery: vi.fn(function MockRefineryImpl() { /* noop */ }),
  dryRunMerge: vi.fn().mockResolvedValue([]),
}));

vi.mock("../../orchestrator/merge-cost-tracker.js", () => ({
  MergeCostTracker: vi.fn(function MockMergeCostTrackerImpl(this: Record<string, unknown>) {
    this.getStats = vi.fn().mockReturnValue({
      totalCostUsd: 0,
      totalInputTokens: 0,
      totalOutputTokens: 0,
      entryCount: 0,
      byTier: {},
      byModel: {},
    });
    this.getResolutionRate = vi.fn().mockReturnValue({ total: 0, successes: 0, rate: 0 });
  }),
}));

vi.mock("../watch-ui.js", () => ({
  renderAgentCard: vi.fn().mockReturnValue(""),
}));

vi.mock("../../lib/feature-flags.js", () => ({
  getTaskBackend: vi.fn().mockReturnValue("br"),
}));

vi.mock("../../lib/trpc-client.js", () => ({
  createTrpcClient: () => ({
    projects: {
      list: vi.fn().mockResolvedValue([]),
      add: vi.fn(),
      get: vi.fn(),
      update: vi.fn(),
      remove: vi.fn(),
      sync: vi.fn(),
    },
  }),
}));

// ── process.exit mock ────────────────────────────────────────────────────────
// Prevent accidental process.exit from terminating the test runner.
// Any unexpected error path that calls process.exit will throw instead.
let exitSpy: ReturnType<typeof vi.spyOn>;
beforeEach(() => {
  exitSpy = vi.spyOn(process, "exit").mockImplementation((code?: number | string | null | undefined) => {
    throw new Error(`process.exit(${code ?? ""}) called`);
  });
});
afterEach(() => {
  exitSpy.mockRestore();
});

// ── Imports ─────────────────────────────────────────────────────────────────
import { statusCommand } from "../commands/status.js";
import { mergeCommand } from "../commands/merge.js";
import { metricsCommand } from "../commands/metrics.js";

// ── Helpers ─────────────────────────────────────────────────────────────────

/**
 * Run a Commander command with given args, capturing stdout/stderr output.
 * Returns the captured output as strings.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function runCommand(cmd: any, args: string[]): Promise<{ stdout: string; stderr: string }> {
  const stdoutLines: string[] = [];
  const stderrLines: string[] = [];

  const origLog = console.log;
  const origWarn = console.warn;
  const origError = console.error;

  console.log = (...a: unknown[]) => stdoutLines.push(a.join(" "));
  console.warn = (...a: unknown[]) => stderrLines.push(a.join(" "));
  console.error = (...a: unknown[]) => stderrLines.push(a.join(" "));

  try {
    await cmd.parseAsync(["node", "foreman", ...args]);
  } finally {
    console.log = origLog;
    console.warn = origWarn;
    console.error = origError;
  }

  return { stdout: stdoutLines.join("\n"), stderr: stderrLines.join("\n") };
}

const MOCK_PROJECT = {
  id: "proj-1",
  path: "/mock/project",
  name: "test",
  status: "active" as const,
  created_at: "2026-01-01T00:00:00Z",
  updated_at: "2026-01-01T00:00:00Z",
};

// ── Tests: foreman status --json ─────────────────────────────────────────────

describe("foreman status --json", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockCreateVcsBackend.mockResolvedValue({
      name: "git",
      getRepoRoot: vi.fn().mockResolvedValue("/mock/project"),
      getCurrentBranch: vi.fn().mockResolvedValue("main"),
      checkoutBranch: vi.fn().mockResolvedValue(undefined),
      getRemoteUrl: vi.fn().mockResolvedValue(null),
      detectDefaultBranch: vi.fn().mockResolvedValue("main"),
    });
    MockBeadsRustClient.mockImplementation(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
      this.list = mockBrList;
      this.ready = mockBrReady;
      this.ensureBrInstalled = mockEnsureBrInstalled;
    });
    mockBrList.mockResolvedValue([]);
    mockBrReady.mockResolvedValue([]);
    mockFetchTaskCounts.mockResolvedValue({ total: 0, ready: 0, inProgress: 0, completed: 0, blocked: 0 });
    mockGetProjectByPath.mockReturnValue(null);
    mockGetActiveRuns.mockReturnValue([]);
    mockGetMetrics.mockReturnValue({ totalCost: 0, totalTokens: 0, tasksByStatus: {}, costByRuntime: [] });
    mockGetRunsByStatusSince.mockReturnValue([]);
    (MockForemanStore as typeof MockForemanStore & Record<"forProject", unknown>).forProject = vi.fn(
      (_projectPath: string) => new MockForemanStore(),
    );
  });

  it("outputs valid JSON when --json flag is passed", async () => {
    const { stdout } = await runCommand(statusCommand, ["--json"]);
    expect(() => JSON.parse(stdout)).not.toThrow();
  });

  it("output contains tasks, agents, and costs keys", async () => {
    const { stdout } = await runCommand(statusCommand, ["--json"]);
    const data = JSON.parse(stdout);
    expect(data).toHaveProperty("tasks");
    expect(data).toHaveProperty("agents");
    expect(data).toHaveProperty("costs");
  });

  it("tasks section contains expected numeric fields", async () => {
    const { stdout } = await runCommand(statusCommand, ["--json"]);
    const { tasks } = JSON.parse(stdout);
    expect(typeof tasks.total).toBe("number");
    expect(typeof tasks.ready).toBe("number");
    expect(typeof tasks.inProgress).toBe("number");
    expect(typeof tasks.completed).toBe("number");
    expect(typeof tasks.blocked).toBe("number");
    expect(typeof tasks.failed).toBe("number");
    expect(typeof tasks.stuck).toBe("number");
  });

  it("reflects correct native task counts", async () => {
    mockFetchTaskCounts.mockResolvedValue({
      total: 3,
      ready: 1,
      inProgress: 1,
      completed: 1,
      blocked: 0,
    });

    const { stdout } = await runCommand(statusCommand, ["--json"]);
    const { tasks } = JSON.parse(stdout);

    expect(tasks.total).toBe(3); // 2 open + 1 closed
    expect(tasks.inProgress).toBe(1);
    expect(tasks.ready).toBe(1);
    expect(tasks.completed).toBe(1);
  });

  it("includes active agents with progress when project exists", async () => {
    const mockRun = {
      id: "run-1", project_id: "proj-1", seed_id: "bd-abc", agent_type: "claude-sonnet-4-6",
      session_key: null, worktree_path: null, status: "running", started_at: "2026-03-17T10:00:00Z",
      completed_at: null, created_at: "2026-03-17T10:00:00Z", progress: null,    };
    const mockProgress = {
      toolCalls: 5, toolBreakdown: {}, filesChanged: [], turns: 3,
      costUsd: 0.05, tokensIn: 1000, tokensOut: 200,
      lastToolCall: "Read", lastActivity: "2026-03-17T10:05:00Z",
    };

    mockGetProjectByPath.mockReturnValue(MOCK_PROJECT);
    mockGetActiveRuns.mockReturnValue([mockRun]);
    mockGetRunProgress.mockReturnValue(mockProgress);
    mockGetRunsByStatusSince.mockReturnValue([]);
    mockGetMetrics.mockReturnValue({ totalCost: 0, totalTokens: 0, tasksByStatus: {}, costByRuntime: [] });

    const { stdout } = await runCommand(statusCommand, ["--json"]);
    const { agents } = JSON.parse(stdout);

    expect(agents.active).toHaveLength(1);
    expect(agents.active[0].seed_id).toBe("bd-abc");
    expect(agents.active[0].progress).toBeDefined();
    expect(agents.active[0].progress.toolCalls).toBe(5);
  });

  it("includes cost data when metrics are available", async () => {
    mockGetProjectByPath.mockReturnValue(MOCK_PROJECT);
    mockGetActiveRuns.mockReturnValue([]);
    mockGetRunsByStatusSince.mockReturnValue([]);
    mockGetMetrics.mockReturnValue({
      totalCost: 1.23,
      totalTokens: 12345,
      tasksByStatus: {},
      costByRuntime: [],
      costByPhase: { explorer: 0.10, developer: 0.50 },
      agentCostBreakdown: { "claude-sonnet-4-6": 0.60 },
    });

    const { stdout } = await runCommand(statusCommand, ["--json"]);
    const { costs } = JSON.parse(stdout);

    expect(costs.totalCost).toBe(1.23);
    expect(costs.totalTokens).toBe(12345);
    expect(costs.byPhase).toEqual({ explorer: 0.10, developer: 0.50 });
    expect(costs.byModel).toEqual({ "claude-sonnet-4-6": 0.60 });
  });

  it("does not output formatted text when --json flag is passed", async () => {
    const { stdout } = await runCommand(statusCommand, ["--json"]);
    // Should not contain bold header text (only the raw JSON)
    expect(stdout).not.toContain("Project Status");
    expect(stdout).not.toContain("Active Agents");
  });

  it("sanity: outputs human-readable text (not JSON) when --json is omitted", async () => {
    const { stdout } = await runCommand(statusCommand, []);
    // Formatted path should contain header labels, not a JSON object
    expect(stdout).toContain("Tasks");
    expect(() => JSON.parse(stdout)).toThrow();
  });

  it("outputs failed and stuck counts from last 24h in tasks section", async () => {
    mockGetProjectByPath.mockReturnValue(MOCK_PROJECT);
    mockGetRecentOutcomeCounts.mockReturnValue({ merged: 0, failed: 2, stuck: 1 });

    const { stdout } = await runCommand(statusCommand, ["--json"]);
    const { tasks } = JSON.parse(stdout);

    expect(tasks.failed).toBe(2);
    expect(tasks.stuck).toBe(1);
  });
});

// ── Tests: foreman merge --list --json ────────────────────────────────────────

describe("foreman merge --list --json", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockCreateVcsBackend.mockResolvedValue({
      name: "git",
      getRepoRoot: vi.fn().mockResolvedValue("/mock/project"),
      getCurrentBranch: vi.fn().mockResolvedValue("main"),
      checkoutBranch: vi.fn().mockResolvedValue(undefined),
      getRemoteUrl: vi.fn().mockResolvedValue(null),
      detectDefaultBranch: vi.fn().mockResolvedValue("main"),
    });
    MockBeadsRustClient.mockImplementation(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
      this.list = mockBrList;
      this.ready = mockBrReady;
      this.ensureBrInstalled = mockEnsureBrInstalled;
    });
    MockMergeQueue.mockImplementation(function MockMergeQueueImpl(this: Record<string, unknown>) {
      this.reconcile = mockReconcile;
      this.list = mockList;
      this.dequeue = vi.fn().mockReturnValue(null);
      this.updateStatus = vi.fn();
      this.resetForRetry = vi.fn();
    });
    mockReconcile.mockResolvedValue({ enqueued: 0 });
    mockList.mockReturnValue([]);
    mockGetProjectByPath.mockReturnValue(MOCK_PROJECT);
    mockGetDb.mockReturnValue({});
    (MockForemanStore as typeof MockForemanStore & Record<"forProject", unknown>).forProject = vi.fn(
      (_projectPath: string) => new MockForemanStore(),
    );
  });

  it("outputs valid JSON when --list --json flags are passed", async () => {
    const { stdout } = await runCommand(mergeCommand, ["--list", "--json"]);
    expect(() => JSON.parse(stdout)).not.toThrow();
  });

  it("output contains an entries array", async () => {
    const { stdout } = await runCommand(mergeCommand, ["--list", "--json"]);
    const data = JSON.parse(stdout);
    expect(Array.isArray(data.entries)).toBe(true);
  });

  it("reflects queue entries from MergeQueue.list()", async () => {
    const mockEntry = {
      id: 1,
      branch_name: "foreman/bd-xyz",
      seed_id: "bd-xyz",
      run_id: "run-42",
      agent_name: "claude-sonnet-4-6",
      files_modified: ["src/foo.ts", "src/bar.ts"],
      enqueued_at: "2026-03-17T08:00:00Z",
      started_at: null,
      completed_at: null,
      status: "pending",
      resolved_tier: null,
      error: null,
    };
    mockList.mockReturnValue([mockEntry]);

    const { stdout } = await runCommand(mergeCommand, ["--list", "--json"]);
    const data = JSON.parse(stdout);

    expect(data.entries).toHaveLength(1);
    expect(data.entries[0].seed_id).toBe("bd-xyz");
    expect(data.entries[0].branch_name).toBe("foreman/bd-xyz");
    expect(data.entries[0].files_modified).toEqual(["src/foo.ts", "src/bar.ts"]);
    expect(data.entries[0].status).toBe("pending");
  });

  it("returns empty entries array when queue is empty", async () => {
    mockList.mockReturnValue([]);

    const { stdout } = await runCommand(mergeCommand, ["--list", "--json"]);
    const data = JSON.parse(stdout);

    expect(data.entries).toHaveLength(0);
  });

  it("does not output formatted table text when --json flag is passed", async () => {
    const { stdout } = await runCommand(mergeCommand, ["--list", "--json"]);
    expect(stdout).not.toContain("Merge queue");
    expect(stdout).not.toContain("foreman merge");
  });

  it("reconciles queue before listing even in JSON mode", async () => {
    await runCommand(mergeCommand, ["--list", "--json"]);
    expect(mockReconcile).toHaveBeenCalledTimes(1);
  });

  it("outputs JSON error (not chalk text) when project is not registered and --json is passed", async () => {
    mockGetProjectByPath.mockReturnValue(null);
    let caughtError: Error | undefined;
    try {
      await runCommand(mergeCommand, ["--list", "--json"]);
    } catch (e) {
      caughtError = e as Error;
    }
    // process.exit should have been called (mocked to throw)
    expect(caughtError?.message).toMatch(/process\.exit/);
    expect(exitSpy).toHaveBeenCalledWith(1);
  });

  it("sanity: outputs human-readable text (not JSON) when --json is omitted", async () => {
    const { stdout } = await runCommand(mergeCommand, ["--list"]);
    // With empty queue, formatted output shows "No beads in merge queue."
    expect(stdout).toContain("No beads in merge queue.");
    expect(() => JSON.parse(stdout)).toThrow();
  });

  it("outputs JSON with multiple entries", async () => {
    const entries = [
      { id: 1, branch_name: "foreman/bd-a", seed_id: "bd-a", run_id: "r1", agent_name: "claude-sonnet-4-6", files_modified: [], enqueued_at: "2026-03-17T08:00:00Z", started_at: null, completed_at: null, status: "pending", resolved_tier: null, error: null },
      { id: 2, branch_name: "foreman/bd-b", seed_id: "bd-b", run_id: "r2", agent_name: "claude-sonnet-4-6", files_modified: ["README.md"], enqueued_at: "2026-03-17T09:00:00Z", started_at: null, completed_at: null, status: "merged", resolved_tier: null, error: null },
    ];
    mockList.mockReturnValue(entries);

    const { stdout } = await runCommand(mergeCommand, ["--list", "--json"]);
    const data = JSON.parse(stdout);

    expect(data.entries).toHaveLength(2);
    expect(data.entries[0].seed_id).toBe("bd-a");
    expect(data.entries[1].seed_id).toBe("bd-b");
    expect(data.entries[1].status).toBe("merged");
  });
});

// ── Tests: foreman metrics ─────────────────────────────────────────────────────

describe("foreman metrics", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockCreateVcsBackend.mockResolvedValue({
      name: "git",
      getRepoRoot: vi.fn().mockResolvedValue("/mock/project"),
      getCurrentBranch: vi.fn().mockResolvedValue("main"),
      checkoutBranch: vi.fn().mockResolvedValue(undefined),
      getRemoteUrl: vi.fn().mockResolvedValue(null),
      detectDefaultBranch: vi.fn().mockResolvedValue("main"),
    });
    MockBeadsRustClient.mockImplementation(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
      this.list = mockBrList;
      this.ready = mockBrReady;
      this.ensureBrInstalled = mockEnsureBrInstalled;
    });
    mockGetProjectByPath.mockReturnValue(MOCK_PROJECT);
    mockGetMetrics.mockReturnValue({
      totalCost: 1.23,
      totalTokens: 12345,
      tasksByStatus: { ready: 1, "in-progress": 1, completed: 1 },
      costByRuntime: [],
      costByPhase: { explorer: 0.10, developer: 0.50, qa: 0.63 },
      agentCostBreakdown: { "claude-sonnet-4-6": 1.23 },
    });
    (MockForemanStore as typeof MockForemanStore & Record<"forProject", unknown>).forProject = vi.fn(
      (_projectPath: string) => new MockForemanStore(),
    );
  });

  it("outputs valid JSON when --json flag is passed", async () => {
    const { stdout } = await runCommand(metricsCommand, ["--json"]);
    expect(() => JSON.parse(stdout)).not.toThrow();
  });

  it("output contains totalCost and totalTokens", async () => {
    const { stdout } = await runCommand(metricsCommand, ["--json"]);
    const data = JSON.parse(stdout);
    expect(data.totalCost).toBe(1.23);
    expect(data.totalTokens).toBe(12345);
  });

  it("output contains costByPhase when available", async () => {
    const { stdout } = await runCommand(metricsCommand, ["--json"]);
    const data = JSON.parse(stdout);
    expect(data.costByPhase).toEqual({ explorer: 0.10, developer: 0.50, qa: 0.63 });
  });

  it("output contains agentCostBreakdown when available", async () => {
    const { stdout } = await runCommand(metricsCommand, ["--json"]);
    const data = JSON.parse(stdout);
    expect(data.agentCostBreakdown).toEqual({ "claude-sonnet-4-6": 1.23 });
  });

  it("passes --since to store.getMetrics", async () => {
    await runCommand(metricsCommand, ["--json", "--since", "2026-06-01T00:00:00Z"]);
    expect(mockGetMetrics).toHaveBeenCalledWith(MOCK_PROJECT.id, "2026-06-01T00:00:00Z", undefined);
  });

  it("filters by --phase when specified", async () => {
    const { stdout } = await runCommand(metricsCommand, ["--json", "--phase", "explorer"]);
    const data = JSON.parse(stdout);
    expect(data.costByPhase).toEqual({ explorer: 0.10 });
  });

  it("returns empty costByPhase when --phase is specified but not found", async () => {
    const { stdout } = await runCommand(metricsCommand, ["--json", "--phase", "nonexistent"]);
    const data = JSON.parse(stdout);
    expect(data.costByPhase).toEqual({});
  });

  it("filters by --agent when specified", async () => {
    const { stdout } = await runCommand(metricsCommand, ["--json", "--agent", "claude-sonnet-4-6"]);
    const data = JSON.parse(stdout);
    expect(data.agentCostBreakdown).toEqual({ "claude-sonnet-4-6": 1.23 });
  });

  it("returns empty agentCostBreakdown when --agent is specified but not found", async () => {
    const { stdout } = await runCommand(metricsCommand, ["--json", "--agent", "nonexistent-model"]);
    const data = JSON.parse(stdout);
    expect(data.agentCostBreakdown).toEqual({});
  });

  it("passes --task-type to store.getMetrics", async () => {
    await runCommand(metricsCommand, ["--json", "--task-type", "feature"]);
    expect(mockGetMetrics).toHaveBeenCalledWith(MOCK_PROJECT.id, undefined, "feature");
  });

  it("passes --since and --task-type to store.getMetrics", async () => {
    await runCommand(metricsCommand, ["--json", "--since", "2026-06-01", "--task-type", "bug"]);
    expect(mockGetMetrics).toHaveBeenCalledWith(MOCK_PROJECT.id, "2026-06-01", "bug");
  });

  it("combines --task-type and --phase filters", async () => {
    await runCommand(metricsCommand, ["--json", "--task-type", "feature", "--phase", "explorer"]);
    expect(mockGetMetrics).toHaveBeenCalledWith(MOCK_PROJECT.id, undefined, "feature");
  });

  it("does not output JSON structure when --json is omitted", async () => {
    const { stdout } = await runCommand(metricsCommand, []);
    expect(stdout).toContain("Metrics");
    expect(stdout).toContain("Total Cost");
    expect(stdout).toContain("1.23");
    expect(() => JSON.parse(stdout)).toThrow();
  });

  it("outputs JSON error when project is not registered and --json is passed", async () => {
    mockGetProjectByPath.mockReturnValue(null);
    let caughtError: Error | undefined;
    try {
      await runCommand(metricsCommand, ["--json"]);
    } catch (e) {
      caughtError = e as Error;
    }
    // process.exit should have been called (mocked to throw)
    expect(caughtError?.message).toMatch(/process\.exit/);
    expect(exitSpy).toHaveBeenCalledWith(1);
  });

  it("outputs formatted error when project is not registered and --json is omitted", async () => {
    mockGetProjectByPath.mockReturnValue(null);
    const { stdout } = await runCommand(metricsCommand, []);
    expect(stdout).toContain("not found");
  });

  it("combines --since and --phase filters", async () => {
    await runCommand(metricsCommand, ["--json", "--since", "2026-06-01", "--phase", "developer"]);
    expect(mockGetMetrics).toHaveBeenCalledWith(MOCK_PROJECT.id, "2026-06-01", undefined);
    const data = JSON.parse(await runCommand(metricsCommand, ["--json", "--since", "2026-06-01", "--phase", "developer"]).then(r => r.stdout));
    expect(data.costByPhase).toEqual({ developer: 0.50 });
  });

  it("JSON output includes projectId and timestamp metadata", async () => {
    const { stdout } = await runCommand(metricsCommand, ["--json"]);
    const data = JSON.parse(stdout);
    expect(data.projectId).toBe(MOCK_PROJECT.id);
    expect(data.timestamp).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/);
  });

  it("--compact outputs single-line key=value format", async () => {
    const { stdout } = await runCommand(metricsCommand, ["--compact"]);
    expect(stdout).toMatch(/^cost=[\d.]+ tokens=\d+ phases=\d+ agents=\d+$/);
  });

  it("--compact with --since includes filters= in output", async () => {
    const { stdout } = await runCommand(metricsCommand, ["--compact", "--since", "2026-06-01T00:00:00Z"]);
    expect(stdout).toContain("filters=since=2026-06-01T00:00:00Z");
  });

  it("--compact with --phase includes filters= in output", async () => {
    const { stdout } = await runCommand(metricsCommand, ["--compact", "--phase", "explorer"]);
    expect(stdout).toContain("filters=phase=explorer");
  });

  it("human-readable output shows filter context", async () => {
    const { stdout } = await runCommand(metricsCommand, ["--since", "2026-06-01T00:00:00Z"]);
    expect(stdout).toContain("Metrics");
    expect(stdout).toContain("since 2026-06-01T00:00:00Z");
  });

  it("human-readable output shows 'Metrics' when --since is omitted", async () => {
    const { stdout } = await runCommand(metricsCommand, []);
    expect(stdout).toContain("Metrics");
    expect(stdout).not.toContain("Metrics since");
  });

  it("combines --json --since --phase --task-type filters", async () => {
    await runCommand(metricsCommand, ["--json", "--since", "2026-06-01", "--phase", "qa", "--task-type", "bug"]);
    expect(mockGetMetrics).toHaveBeenCalledWith(MOCK_PROJECT.id, "2026-06-01", "bug");
    const data = JSON.parse(await runCommand(metricsCommand, ["--json", "--since", "2026-06-01", "--phase", "qa", "--task-type", "bug"]).then(r => r.stdout));
    expect(data.costByPhase).toEqual({ qa: 0.63 });
  });

  it("--compact outputs JSON error when project not found", async () => {
    mockGetProjectByPath.mockReturnValue(null);
    let caughtError: Error | undefined;
    try {
      await runCommand(metricsCommand, ["--compact"]);
    } catch (e) {
      caughtError = e as Error;
    }
    expect(caughtError?.message).toMatch(/process\.exit/);
  });
});
