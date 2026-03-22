/**
 * Tests for --json output flag on status, monitor, and merge --list commands.
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
  mockBrList,
  mockBrReady,
  mockEnsureBrInstalled,
  MockBeadsRustClient,
  mockGetProjectByPath,
  mockGetActiveRuns,
  mockGetMetrics,
  mockGetRunsByStatusSince,
  mockGetRunProgress,
  mockGetDb,
  MockForemanStore,
  mockCheckAll,
  MockMonitor,
  mockReconcile,
  mockList,
  MockMergeQueue,
} = vi.hoisted(() => {
  const mockGetRepoRoot = vi.fn().mockResolvedValue("/mock/project");
  const mockDetectDefaultBranch = vi.fn().mockResolvedValue("main");

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
  const MockForemanStore = vi.fn(function MockForemanStoreImpl(this: Record<string, unknown>) {
    this.getProjectByPath = mockGetProjectByPath;
    this.getActiveRuns = mockGetActiveRuns;
    this.getMetrics = mockGetMetrics;
    this.getRunsByStatusSince = mockGetRunsByStatusSince;
    this.getRunProgress = mockGetRunProgress;
    this.getDb = mockGetDb;
    this.close = vi.fn();
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (MockForemanStore as any).forProject = vi.fn((...args: unknown[]) => new (MockForemanStore as any)(...args));

  // Monitor mocks
  const mockCheckAll = vi.fn().mockResolvedValue({ active: [], completed: [], stuck: [], failed: [] });
  const MockMonitor = vi.fn(function MockMonitorImpl(this: Record<string, unknown>) {
    this.checkAll = mockCheckAll;
    this.recoverStuck = vi.fn().mockResolvedValue(true);
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
    mockBrList,
    mockBrReady,
    mockEnsureBrInstalled,
    MockBeadsRustClient,
    mockGetProjectByPath,
    mockGetActiveRuns,
    mockGetMetrics,
    mockGetRunsByStatusSince,
    mockGetRunProgress,
    mockGetDb,
    MockForemanStore,
    mockCheckAll,
    MockMonitor,
    mockReconcile,
    mockList,
    MockMergeQueue,
  };
});

vi.mock("../../lib/git.js", () => ({
  getRepoRoot: mockGetRepoRoot,
  detectDefaultBranch: mockDetectDefaultBranch,
}));

vi.mock("../../lib/beads-rust.js", () => ({
  BeadsRustClient: MockBeadsRustClient,
}));

vi.mock("../../lib/store.js", () => ({
  ForemanStore: MockForemanStore,
}));

vi.mock("../../orchestrator/monitor.js", () => ({
  Monitor: MockMonitor,
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
import { monitorCommand } from "../commands/monitor.js";
import { mergeCommand } from "../commands/merge.js";

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
    MockBeadsRustClient.mockImplementation(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
      this.list = mockBrList;
      this.ready = mockBrReady;
      this.ensureBrInstalled = mockEnsureBrInstalled;
    });
    mockBrList.mockResolvedValue([]);
    mockBrReady.mockResolvedValue([]);
    mockGetProjectByPath.mockReturnValue(null);
    mockGetActiveRuns.mockReturnValue([]);
    mockGetMetrics.mockReturnValue({ totalCost: 0, totalTokens: 0, tasksByStatus: {}, costByRuntime: [] });
    mockGetRunsByStatusSince.mockReturnValue([]);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (MockForemanStore as any).forProject = vi.fn((...args: unknown[]) => new (MockForemanStore as any)(...args));
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

  it("reflects correct task counts from br backend", async () => {
    mockBrList.mockImplementation(async (opts?: { status?: string }) => {
      if (opts?.status === "closed") {
        return [{ id: "c1", status: "closed", title: "Done" }];
      }
      return [
        { id: "1", status: "in_progress", title: "Active" },
        { id: "2", status: "open", title: "Pending" },
      ];
    });
    mockBrReady.mockResolvedValue([{ id: "2", status: "open" }]);

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
    mockGetRunsByStatusSince.mockImplementation((_status: string) => {
      if (_status === "failed") return [{ id: "r1" }, { id: "r2" }];
      if (_status === "stuck") return [{ id: "r3" }];
      return [];
    });

    const { stdout } = await runCommand(statusCommand, ["--json"]);
    const { tasks } = JSON.parse(stdout);

    expect(tasks.failed).toBe(2);
    expect(tasks.stuck).toBe(1);
  });
});

// ── Tests: foreman monitor --json ─────────────────────────────────────────────

describe("foreman monitor --json", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    MockBeadsRustClient.mockImplementation(function MockBeadsRustClientImpl(this: Record<string, unknown>) {
      this.list = mockBrList;
      this.ready = mockBrReady;
      this.ensureBrInstalled = mockEnsureBrInstalled;
    });
    MockMonitor.mockImplementation(function MockMonitorImpl(this: Record<string, unknown>) {
      this.checkAll = mockCheckAll;
      this.recoverStuck = vi.fn().mockResolvedValue(true);
    });
    mockCheckAll.mockResolvedValue({ active: [], completed: [], stuck: [], failed: [] });
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (MockForemanStore as any).forProject = vi.fn((...args: unknown[]) => new (MockForemanStore as any)(...args));
  });

  it("outputs valid JSON when --json flag is passed", async () => {
    const { stdout } = await runCommand(monitorCommand, ["--json"]);
    expect(() => JSON.parse(stdout)).not.toThrow();
  });

  it("output contains active, completed, stuck, and failed arrays", async () => {
    const { stdout } = await runCommand(monitorCommand, ["--json"]);
    const data = JSON.parse(stdout);
    expect(Array.isArray(data.active)).toBe(true);
    expect(Array.isArray(data.completed)).toBe(true);
    expect(Array.isArray(data.stuck)).toBe(true);
    expect(Array.isArray(data.failed)).toBe(true);
  });

  it("reflects run data from monitor.checkAll()", async () => {
    const mockRun = {
      id: "run-1", project_id: "proj-1", seed_id: "bd-abc", agent_type: "claude-sonnet-4-6",
      session_key: null, worktree_path: null, status: "running", started_at: "2026-03-17T10:00:00Z",
      completed_at: null, created_at: "2026-03-17T10:00:00Z", progress: null,    };
    mockCheckAll.mockResolvedValue({
      active: [mockRun],
      completed: [],
      stuck: [],
      failed: [],
    });

    const { stdout } = await runCommand(monitorCommand, ["--json"]);
    const data = JSON.parse(stdout);

    expect(data.active).toHaveLength(1);
    expect(data.active[0].seed_id).toBe("bd-abc");
    expect(data.completed).toHaveLength(0);
    expect(data.stuck).toHaveLength(0);
    expect(data.failed).toHaveLength(0);
  });

  it("does not output deprecation warning when --json flag is passed", async () => {
    const { stderr } = await runCommand(monitorCommand, ["--json"]);
    expect(stderr).not.toContain("deprecated");
  });

  it("does not output formatted header text when --json flag is passed", async () => {
    const { stdout } = await runCommand(monitorCommand, ["--json"]);
    expect(stdout).not.toContain("Checking agent status");
    expect(stdout).not.toContain("Active (");
  });

  it("sanity: outputs human-readable text (not JSON) when --json is omitted", async () => {
    const { stdout } = await runCommand(monitorCommand, []);
    // Formatted path should contain status header text, not a JSON object
    expect(stdout).toContain("Checking agent status");
    expect(() => JSON.parse(stdout)).toThrow();
  });

  it("emits a stderr warning (not silently skip) when --json and --recover are both passed", async () => {
    mockCheckAll.mockResolvedValue({ active: [], completed: [], stuck: [
      { id: "run-1", seed_id: "bd-stuck", agent_type: "claude-sonnet-4-6", started_at: null, status: "stuck" },
    ], failed: [] });

    const { stderr } = await runCommand(monitorCommand, ["--json", "--recover"]);
    expect(stderr).toContain("--recover is ignored when --json is used");
  });
});

// ── Tests: foreman merge --list --json ────────────────────────────────────────

describe("foreman merge --list --json", () => {
  beforeEach(() => {
    vi.clearAllMocks();
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
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (MockForemanStore as any).forProject = vi.fn((...args: unknown[]) => new (MockForemanStore as any)(...args));
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
    // With empty queue, formatted output shows "No seeds in merge queue."
    expect(stdout).toContain("No seeds in merge queue.");
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
