/**
 * Tests for sentinel auto-start behavior in `foreman run`.
 *
 * Verifies:
 * - SentinelAgent.start() is called when sentinel.enabled=1 in config
 * - SentinelAgent is NOT started when sentinel.enabled=0
 * - SentinelAgent is NOT started when getSentinelConfig returns null
 * - SentinelAgent is NOT started in --dry-run mode
 * - SentinelAgent is NOT started when getProjectByPath returns null
 * - SentinelAgent.stop() is called when foreman run exits normally
 * - A startup warning is logged (non-fatal) if SentinelAgent.start() throws
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// ── Hoisted mocks ────────────────────────────────────────────────────────────

const {
  mockEnsureBrInstalled,
  MockBeadsRustClient,
  MockBvClient,
  mockDispatch,
  MockDispatcher,
  mockGetActiveRuns,
  mockGetProjectByPath,
  mockGetSentinelConfig,
  mockGetRunsByStatuses,
  MockForemanStore,
  mockWatchRunsInk,
  mockSentinelStart,
  mockSentinelStop,
  mockSentinelIsRunning,
  MockSentinelAgent,
  mockVcsCreate,
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
  const mockGetSentinelConfig = vi.fn().mockReturnValue(null);
  const mockGetRunsByStatuses = vi.fn().mockReturnValue([]);

  const MockForemanStore = vi.fn(function (this: Record<string, unknown>) {
    this.close = vi.fn();
    this.getActiveRuns = mockGetActiveRuns;
    this.getProjectByPath = mockGetProjectByPath;
    this.getSentinelConfig = mockGetSentinelConfig;
    this.getRunsByStatuses = mockGetRunsByStatuses;
  });
  (MockForemanStore as any).forProject = vi.fn(
    (...args: unknown[]) => new (MockForemanStore as any)(...args)
  );

  const mockWatchRunsInk = vi.fn().mockResolvedValue({ detached: false });

  const mockSentinelStart = vi.fn();
  const mockSentinelStop = vi.fn();
  const mockSentinelIsRunning = vi.fn().mockReturnValue(false);
  const MockSentinelAgent = vi.fn(function (this: Record<string, unknown>) {
    this.start = mockSentinelStart;
    this.stop = mockSentinelStop;
    this.isRunning = mockSentinelIsRunning;
  });

  const mockVcsCreate = vi.fn().mockResolvedValue({
    getRepoRoot: vi.fn().mockResolvedValue("/mock/project"),
    detectDefaultBranch: vi.fn().mockResolvedValue("main"),
  });

  return {
    mockEnsureBrInstalled,
    MockBeadsRustClient,
    MockBvClient,
    mockDispatch,
    MockDispatcher,
    mockGetActiveRuns,
    mockGetProjectByPath,
    mockGetSentinelConfig,
    mockGetRunsByStatuses,
    MockForemanStore,
    mockWatchRunsInk,
    mockSentinelStart,
    mockSentinelStop,
    mockSentinelIsRunning,
    MockSentinelAgent,
    mockVcsCreate,
  };
});

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
vi.mock("../../lib/beads-rust.js", () => ({ BeadsRustClient: MockBeadsRustClient }));
// Skip runtime asset preflight — no prompts/workflows in test env
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
  watchRunsInk: (...args: unknown[]) => mockWatchRunsInk(...args),
}));
vi.mock("../../orchestrator/sentinel.js", () => ({ SentinelAgent: MockSentinelAgent }));
vi.mock("../../orchestrator/pi-rpc-spawn-strategy.js", () => ({
  isPiAvailable: vi.fn().mockReturnValue(false),
  PiRpcSpawnStrategy: vi.fn(),
  PI_PHASE_CONFIGS: {},
  parsePiEvent: vi.fn().mockReturnValue(null),
}));

// ── Module under test ─────────────────────────────────────────────────────────
import { runCommand } from "../commands/run.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

const MOCK_PROJECT = { id: "proj-123", path: "/mock/project", name: "test" };

const MOCK_SENTINEL_CONFIG = {
  id: 1,
  project_id: "proj-123",
  branch: "main",
  test_command: "npm test",
  interval_minutes: 30,
  failure_threshold: 2,
  enabled: 1 as 0 | 1,
  pid: null,
  created_at: "2026-01-01T00:00:00Z",
  updated_at: "2026-01-01T00:00:00Z",
};

async function invokeRun(args: string[]): Promise<void> {
  await runCommand.parseAsync(args, { from: "user" });
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("sentinel auto-start in foreman run", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(console, "warn").mockImplementation(() => {});

    // Default: no tasks dispatched, no active agents
    // Use --no-watch so tests exit immediately without polling loop
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
      this.getActiveRuns = mockGetActiveRuns;
      this.getProjectByPath = mockGetProjectByPath;
      this.getSentinelConfig = mockGetSentinelConfig;
      this.getRunsByStatuses = mockGetRunsByStatuses;
      this.getMergeAgentConfig = vi.fn().mockReturnValue(null);
    });
    (MockForemanStore as any).forProject = vi.fn(
      (...args: unknown[]) => new (MockForemanStore as any)(...args)
    );
    mockWatchRunsInk.mockResolvedValue({ detached: false });
    mockGetActiveRuns.mockReturnValue([]);
    mockGetProjectByPath.mockReturnValue(null);
    mockVcsCreate.mockResolvedValue({
      getRepoRoot: vi.fn().mockResolvedValue("/mock/project"),
      detectDefaultBranch: vi.fn().mockResolvedValue("main"),
    });
    mockGetSentinelConfig.mockReturnValue(null);
    mockGetRunsByStatuses.mockReturnValue([]);

    mockSentinelStart.mockImplementation(() => {});
    mockSentinelStop.mockImplementation(() => {});
    mockSentinelIsRunning.mockReturnValue(false);
    MockSentinelAgent.mockImplementation(function (this: Record<string, unknown>) {
      this.start = mockSentinelStart;
      this.stop = mockSentinelStop;
      this.isRunning = mockSentinelIsRunning;
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("starts SentinelAgent when sentinel.enabled=1 in config", async () => {
    mockGetProjectByPath.mockReturnValue(MOCK_PROJECT);
    mockGetSentinelConfig.mockReturnValue(MOCK_SENTINEL_CONFIG);

    await invokeRun(["--no-watch"]);

    expect(MockSentinelAgent).toHaveBeenCalledOnce();
    expect(MockSentinelAgent).toHaveBeenCalledWith(
      expect.anything(), // store
      expect.anything(), // brClient
      MOCK_PROJECT.id,
      "/mock/project",
    );
    expect(mockSentinelStart).toHaveBeenCalledOnce();
    expect(mockSentinelStart).toHaveBeenCalledWith(
      {
        branch: "main",
        testCommand: "npm test",
        intervalMinutes: 30,
        failureThreshold: 2,
      },
      expect.any(Function), // onResult callback
    );
  });

  it("does NOT start SentinelAgent when sentinel.enabled=0", async () => {
    mockGetProjectByPath.mockReturnValue(MOCK_PROJECT);
    mockGetSentinelConfig.mockReturnValue({ ...MOCK_SENTINEL_CONFIG, enabled: 0 });

    await invokeRun(["--no-watch"]);

    expect(MockSentinelAgent).not.toHaveBeenCalled();
    expect(mockSentinelStart).not.toHaveBeenCalled();
  });

  it("does NOT start SentinelAgent when getSentinelConfig returns null", async () => {
    mockGetProjectByPath.mockReturnValue(MOCK_PROJECT);
    mockGetSentinelConfig.mockReturnValue(null);

    await invokeRun(["--no-watch"]);

    expect(MockSentinelAgent).not.toHaveBeenCalled();
    expect(mockSentinelStart).not.toHaveBeenCalled();
  });

  it("does NOT start SentinelAgent when project is not initialized", async () => {
    mockGetProjectByPath.mockReturnValue(null);

    await invokeRun(["--no-watch"]);

    expect(MockSentinelAgent).not.toHaveBeenCalled();
    expect(mockSentinelStart).not.toHaveBeenCalled();
  });

  it("does NOT start SentinelAgent in --dry-run mode", async () => {
    mockGetProjectByPath.mockReturnValue(MOCK_PROJECT);
    mockGetSentinelConfig.mockReturnValue(MOCK_SENTINEL_CONFIG);

    await invokeRun(["--dry-run"]);

    expect(MockSentinelAgent).not.toHaveBeenCalled();
    expect(mockSentinelStart).not.toHaveBeenCalled();
  });

  it("stops SentinelAgent when foreman run exits normally", async () => {
    mockGetProjectByPath.mockReturnValue(MOCK_PROJECT);
    mockGetSentinelConfig.mockReturnValue(MOCK_SENTINEL_CONFIG);
    // isRunning returns true after start
    mockSentinelIsRunning.mockReturnValue(true);

    await invokeRun(["--no-watch"]);

    expect(mockSentinelStop).toHaveBeenCalledOnce();
  });

  it("does NOT call stop if sentinel was never started", async () => {
    // No project — sentinel not started
    mockGetProjectByPath.mockReturnValue(null);
    mockSentinelIsRunning.mockReturnValue(false);

    await invokeRun(["--no-watch"]);

    expect(mockSentinelStop).not.toHaveBeenCalled();
  });

  it("logs a warning (non-fatal) if SentinelAgent.start() throws", async () => {
    mockGetProjectByPath.mockReturnValue(MOCK_PROJECT);
    mockGetSentinelConfig.mockReturnValue(MOCK_SENTINEL_CONFIG);
    mockSentinelStart.mockImplementation(() => {
      throw new Error("sentinel start failed");
    });

    // Should not throw; foreman run continues normally
    await expect(invokeRun(["--no-watch"])).resolves.not.toThrow();

    expect(console.warn).toHaveBeenCalledWith(
      expect.stringContaining("[sentinel] Failed to auto-start"),
    );
  });

  it("passes correct config values from store to SentinelAgent.start()", async () => {
    const customConfig = {
      ...MOCK_SENTINEL_CONFIG,
      branch: "develop",
      test_command: "yarn test:ci",
      interval_minutes: 15,
      failure_threshold: 3,
    };
    mockGetProjectByPath.mockReturnValue(MOCK_PROJECT);
    mockGetSentinelConfig.mockReturnValue(customConfig);

    await invokeRun(["--no-watch"]);

    expect(mockSentinelStart).toHaveBeenCalledWith(
      {
        branch: "develop",
        testCommand: "yarn test:ci",
        intervalMinutes: 15,
        failureThreshold: 3,
      },
      expect.any(Function),
    );
  });
});
