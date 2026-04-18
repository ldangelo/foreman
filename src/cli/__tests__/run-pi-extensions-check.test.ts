/**
 * Tests for the Pi extensions build check in `foreman run`.
 *
 * Verifies:
 * - No error when Pi is NOT available (check is skipped entirely)
 * - No error when Pi IS available and the dist/index.js exists
 * - Exits with process.exit(1) when Pi IS available but dist/index.js is missing
 * - No error in --dry-run mode even when Pi is available and dist is missing
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// ── Hoisted mocks ─────────────────────────────────────────────────────────────

const {
  mockIsPiAvailable,
  mockExistsSync,
  mockEnsureBrInstalled,
  MockBeadsRustClient,
  MockBvClient,
  mockDispatch,
  MockDispatcher,
  MockForemanStore,
  mockVcsCreate,
} = vi.hoisted(() => {
  const mockIsPiAvailable = vi.fn().mockReturnValue(false);
  const mockExistsSync = vi.fn().mockReturnValue(true);
  const mockEnsureBrInstalled = vi.fn().mockResolvedValue(undefined);

  const MockBeadsRustClient = vi.fn(function (this: Record<string, unknown>) {
    this.ensureBrInstalled = mockEnsureBrInstalled;
  });
  const MockBvClient = vi.fn(function () { /* noop */ });

  const mockDispatch = vi.fn().mockResolvedValue({
    dispatched: [],
    skipped: [],
    activeAgents: 0,
  });
  const MockDispatcher = vi.fn(function (this: Record<string, unknown>) {
    this.dispatch = mockDispatch;
    this.resumeRuns = vi.fn().mockResolvedValue({
      resumed: [],
      skipped: [],
      activeAgents: 0,
    });
  });

  const MockForemanStore = vi.fn(function (this: Record<string, unknown>) {
    this.close = vi.fn();
    this.getActiveRuns = vi.fn().mockReturnValue([]);
    this.getProjectByPath = vi.fn().mockReturnValue(null);
    this.getSentinelConfig = vi.fn().mockReturnValue(null);
    this.getRunsByStatuses = vi.fn().mockReturnValue([]);
  });
  (MockForemanStore as any).forProject = vi.fn(
    (...args: unknown[]) => new (MockForemanStore as any)(...args),
  );

  const mockVcsCreate = vi.fn().mockResolvedValue({
    getRepoRoot: vi.fn().mockResolvedValue("/mock/project"),
    getCurrentBranch: vi.fn().mockResolvedValue("main"),
    detectDefaultBranch: vi.fn().mockResolvedValue("main"),
  });

  return {
    mockIsPiAvailable,
    mockExistsSync,
    mockEnsureBrInstalled,
    MockBeadsRustClient,
    MockBvClient,
    mockDispatch,
    MockDispatcher,
    MockForemanStore,
    mockVcsCreate,
  };
});

vi.mock("../../orchestrator/pi-rpc-spawn-strategy.js", () => ({
  isPiAvailable: () => mockIsPiAvailable(),
  PiRpcSpawnStrategy: vi.fn(),
  PI_PHASE_CONFIGS: {},
  parsePiEvent: vi.fn(),
}));

vi.mock("node:fs", () => ({
  existsSync: (...args: unknown[]) => mockExistsSync(...args),
}));

vi.mock("../../lib/beads-rust.js", () => ({ BeadsRustClient: MockBeadsRustClient }));
// Needed so collectRuntimeAssetIssues() finds no missing/stale prompts/workflows
// when FOREMAN_RUNTIME_MODE=normal (test overrides to run the Pi extension check).
vi.mock("../../lib/prompt-loader.js", () => ({
  findMissingPrompts: () => [],
  findStalePrompts: () => [],
}));
vi.mock("../../lib/workflow-loader.js", () => ({
  findMissingWorkflows: () => [],
  findStaleWorkflows: () => [],
}));
vi.mock("../../lib/bv.js", () => ({ BvClient: MockBvClient }));
vi.mock("../../orchestrator/dispatcher.js", () => ({ Dispatcher: MockDispatcher }));
vi.mock("../../lib/store.js", () => ({ ForemanStore: MockForemanStore }));
vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: (...args: unknown[]) => mockVcsCreate(...args),
  },
}));
vi.mock("../../orchestrator/notification-server.js", () => ({
  NotificationServer: vi.fn(function (this: Record<string, unknown>) {
    this.start = vi.fn().mockResolvedValue(undefined);
    this.stop = vi.fn().mockResolvedValue(undefined);
    this.url = "http://127.0.0.1:9999";
  }),
}));
vi.mock("../../orchestrator/notification-bus.js", () => ({ notificationBus: {} }));
vi.mock("../watch-ui.js", () => ({
  watchRunsInk: vi.fn().mockResolvedValue({ detached: false }),
}));
vi.mock("../../orchestrator/sentinel.js", () => ({
  SentinelAgent: vi.fn(function (this: Record<string, unknown>) {
    this.start = vi.fn();
    this.stop = vi.fn();
    this.isRunning = vi.fn().mockReturnValue(false);
  }),
}));
vi.mock("../../orchestrator/task-backend-ops.js", () => ({
  syncBeadStatusOnStartup: vi.fn().mockResolvedValue({ synced: 0, mismatches: [], errors: [] }),
}));
vi.mock("../../orchestrator/auto-merge.js", () => ({
  autoMerge: vi.fn().mockResolvedValue({ merged: 0, conflicts: 0, failed: 0 }),
}));
vi.mock("../../lib/run-status.js", () => ({
  mapRunStatusToSeedStatus: vi.fn(),
}));
vi.mock("../../lib/config.js", () => ({
  PIPELINE_TIMEOUTS: {
    beadClosureMs: 5000,
    monitorPollMs: 5000,
  },
  STUCK_RETRY_CONFIG: { maxRetries: 3, initialDelayMs: 60000, maxDelayMs: 3600000, backoffMultiplier: 2, windowMs: 86400000 },
  calculateStuckBackoffMs: (n: number) => n <= 0 ? 0 : Math.min(60000 * Math.pow(2, n - 1), 3600000),
  getDefaultModel: () => "minimax/MiniMax-M2.7",
  getHighspeedModel: () => "minimax/MiniMax-M2.7-highspeed",
  getExplorerBudget: () => 1.0,
  getDeveloperBudget: () => 5.0,
  getQaBudget: () => 3.0,
  getReviewerBudget: () => 2.0,
  getPlanStepBudget: () => 3.0,
  getSentinelBudget: () => 2.0,
  getTroubleshooterBudget: () => 1.5,
  getSessionLogBudget: () => 0.5,
  readBudgetFromEnv: (_name: string, defaultValue: number) => defaultValue,
}));

// ── Module under test ─────────────────────────────────────────────────────────

import { runCommand } from "../commands/run.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

async function invokeRun(args: string[]): Promise<void> {
  await runCommand.parseAsync(args, { from: "user" });
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("Pi extensions build check in foreman run", () => {
  let mockProcessExit: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    vi.clearAllMocks();
    // Override test-mode env var so Pi extension check runs (not skipped).
    // collectRuntimeAssetIssues() returns [] via mocked prompt/workflow loaders.
    process.env.FOREMAN_RUNTIME_MODE = "normal";
    vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(console, "warn").mockImplementation(() => {});

    // Prevent process.exit from actually killing the test process
    mockProcessExit = vi.spyOn(process, "exit").mockImplementation((_code?: number | string | null | undefined) => {
      throw new Error(`process.exit(${_code})`);
    });

    // Default: Pi not available, no relevant files present, no tasks dispatched
    mockIsPiAvailable.mockReturnValue(false);
    mockExistsSync.mockImplementation(() => false);
    mockDispatch.mockResolvedValue({ dispatched: [], skipped: [], activeAgents: 0 });

    // Restore constructor implementations after clearAllMocks
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
      this.getActiveRuns = vi.fn().mockReturnValue([]);
      this.getProjectByPath = vi.fn().mockReturnValue(null);
      this.getSentinelConfig = vi.fn().mockReturnValue(null);
      this.getRunsByStatuses = vi.fn().mockReturnValue([]);
      this.getMergeAgentConfig = vi.fn().mockReturnValue(null);
    });
    (MockForemanStore as any).forProject = vi.fn(
      (...args: unknown[]) => new (MockForemanStore as any)(...args),
    );
    mockVcsCreate.mockResolvedValue({
      getRepoRoot: vi.fn().mockResolvedValue("/mock/project"),
      getCurrentBranch: vi.fn().mockResolvedValue("main"),
      detectDefaultBranch: vi.fn().mockResolvedValue("main"),
    });
  });

  afterEach(() => {
    delete process.env.FOREMAN_RUNTIME_MODE;
    vi.restoreAllMocks();
  });

  it("does not error when Pi is NOT available (check is skipped)", async () => {
    mockIsPiAvailable.mockReturnValue(false);
    mockExistsSync.mockImplementation(() => false); // dist missing, but irrelevant

    await invokeRun(["--resume", "--no-watch"]);

    expect(mockProcessExit).not.toHaveBeenCalled();
  });

  it("does not error when Pi IS available and dist/index.js exists", async () => {
    mockIsPiAvailable.mockReturnValue(true);
    mockExistsSync.mockImplementation((p: unknown) => String(p).endsWith("packages/foreman-pi-extensions/dist/index.js")); // dist present

    await invokeRun(["--resume", "--no-watch"]);

    expect(mockProcessExit).not.toHaveBeenCalled();
  });

  it("exits with process.exit(1) when Pi IS available but dist/index.js is missing", async () => {
    mockIsPiAvailable.mockReturnValue(true);
    mockExistsSync.mockImplementation(() => false); // dist missing

    await expect(invokeRun(["--no-watch"])).rejects.toThrow("process.exit(1)");

    expect(mockProcessExit).toHaveBeenCalledWith(1);
    expect(console.error).toHaveBeenCalledWith(
      expect.stringContaining("Pi extensions package has not been built"),
    );
  });

  it("does not error in --dry-run mode even when Pi is available and dist is missing", async () => {
    mockIsPiAvailable.mockReturnValue(true);
    mockExistsSync.mockImplementation(() => false); // dist missing

    await invokeRun(["--dry-run", "--no-watch"]);

    expect(mockProcessExit).not.toHaveBeenCalled();
  });
});
