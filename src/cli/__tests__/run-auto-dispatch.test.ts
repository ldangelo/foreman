/**
 * Tests for auto-dispatch behavior in the run command.
 *
 * Verifies that:
 * - watchRunsInk is called with an autoDispatch callback when auto-dispatch is enabled
 * - watchRunsInk is called without autoDispatch when --no-auto-dispatch is passed
 * - autoDispatch is not passed in dry-run mode
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
  MockForemanStore,
  mockWatchRunsInk,
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
  const MockForemanStore = vi.fn(function (this: Record<string, unknown>) {
    this.close = vi.fn();
    this.getActiveRuns = mockGetActiveRuns;
    this.getProjectByPath = mockGetProjectByPath;
    this.getMergeAgentConfig = vi.fn().mockReturnValue(null);
  });
  (MockForemanStore as any).forProject = vi.fn((...args: unknown[]) => new (MockForemanStore as any)(...args));

  const mockWatchRunsInk = vi.fn().mockResolvedValue({ detached: false });

  return {
    mockEnsureBrInstalled,
    MockBeadsRustClient,
    MockBvClient,
    mockDispatch,
    MockDispatcher,
    mockGetActiveRuns,
    mockGetProjectByPath,
    MockForemanStore,
    mockWatchRunsInk,
  };
});

vi.mock("../../lib/beads-rust.js", () => ({ BeadsRustClient: MockBeadsRustClient }));
vi.mock("../../lib/bv.js", () => ({ BvClient: MockBvClient }));
vi.mock("../../orchestrator/dispatcher.js", () => ({ Dispatcher: MockDispatcher }));
vi.mock("../../lib/store.js", () => ({ ForemanStore: MockForemanStore }));
vi.mock("../../lib/git.js", () => ({ getRepoRoot: vi.fn().mockResolvedValue("/mock/project") }));
vi.mock("../../orchestrator/notification-server.js", () => ({
  NotificationServer: vi.fn(function (this: Record<string, unknown>) {
    this.start = vi.fn().mockResolvedValue(undefined);
    this.stop = vi.fn().mockResolvedValue(undefined);
    this.url = "http://127.0.0.1:9999";
  }),
}));
vi.mock("../../orchestrator/notification-bus.js", () => ({ notificationBus: {} }));
vi.mock("../watch-ui.js", () => ({ watchRunsInk: (...args: unknown[]) => mockWatchRunsInk(...args) }));
vi.mock("../../orchestrator/agent-mail-client.js", () => ({
  AgentMailClient: vi.fn(function (this: Record<string, unknown>) {
    this.healthCheck = vi.fn().mockResolvedValue(true);
  }),
  DEFAULT_AGENT_MAIL_CONFIG: { baseUrl: "http://localhost:8766" },
}));
vi.mock("../../orchestrator/merge-agent.js", () => ({
  MergeAgent: vi.fn(function (this: Record<string, unknown>) {
    this.start = vi.fn().mockResolvedValue(undefined);
    this.stop = vi.fn();
  }),
  MERGE_AGENT_MAILBOX: "refinery",
  DEFAULT_POLL_INTERVAL_MS: 30_000,
}));

// ── Module under test ─────────────────────────────────────────────────────────
import { runCommand } from "../commands/run.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

async function invokeRun(args: string[]): Promise<void> {
  await runCommand.parseAsync(args, { from: "user" });
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("auto-dispatch: passes callback to watchRunsInk", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});

    // Restore constructor implementations after clearAllMocks resets them
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
      this.getMergeAgentConfig = vi.fn().mockReturnValue(null);
    });
    mockWatchRunsInk.mockResolvedValue({ detached: false });
    mockGetActiveRuns.mockReturnValue([]);
    mockGetProjectByPath.mockReturnValue(null);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("passes autoDispatch callback to watchRunsInk by default (watch mode)", async () => {
    // Dispatch 1 task; watchRunsInk returns detached=true to exit cleanly
    // (without detaching, the loop would continue polling for new tasks)
    mockDispatch.mockResolvedValueOnce({
      dispatched: [
        { seedId: "s-1", runId: "run-111", title: "Task 1", model: "claude-sonnet-4-6", worktreePath: "/tmp/wt", branchName: "foreman/s-1", runtime: "claude-code" },
      ],
      skipped: [],
      activeAgents: 1,
    });
    mockWatchRunsInk.mockResolvedValue({ detached: true });

    await invokeRun([]);

    // watchRunsInk should have been called with autoDispatch callback
    expect(mockWatchRunsInk).toHaveBeenCalledWith(
      expect.anything(), // store
      ["run-111"],
      expect.objectContaining({ autoDispatch: expect.any(Function) }),
    );
  });

  it("does NOT pass autoDispatch when --no-auto-dispatch is set", async () => {
    // Dispatch 1 task; watchRunsInk returns detached=true to exit cleanly
    mockDispatch.mockResolvedValueOnce({
      dispatched: [
        { seedId: "s-2", runId: "run-222", title: "Task 2", model: "claude-sonnet-4-6", worktreePath: "/tmp/wt", branchName: "foreman/s-2", runtime: "claude-code" },
      ],
      skipped: [],
      activeAgents: 1,
    });
    mockWatchRunsInk.mockResolvedValue({ detached: true });

    await invokeRun(["--no-auto-dispatch"]);

    // watchRunsInk should have been called WITHOUT autoDispatch key in opts
    expect(mockWatchRunsInk).toHaveBeenCalledWith(
      expect.anything(),
      ["run-222"],
      expect.not.objectContaining({ autoDispatch: expect.anything() }),
    );
  });

  it("does NOT pass autoDispatch in dry-run mode", async () => {
    mockDispatch.mockResolvedValue({ dispatched: [], skipped: [], activeAgents: 0 });

    await invokeRun(["--dry-run"]);

    // watchRunsInk should NOT be called at all in dry-run
    expect(mockWatchRunsInk).not.toHaveBeenCalled();
  });

  it("does NOT pass autoDispatch when --no-watch is set", async () => {
    mockDispatch.mockResolvedValue({
      dispatched: [
        { seedId: "s-3", runId: "run-333", title: "Task 3", model: "claude-sonnet-4-6", worktreePath: "/tmp/wt", branchName: "foreman/s-3", runtime: "claude-code" },
      ],
      skipped: [],
      activeAgents: 1,
    });

    await invokeRun(["--no-watch"]);

    // watchRunsInk should NOT be called in --no-watch mode
    expect(mockWatchRunsInk).not.toHaveBeenCalled();
  });

  it("autoDispatch callback calls dispatcher.dispatch when invoked", async () => {
    let capturedAutoDispatch: (() => Promise<string[]>) | undefined;

    // Capture the autoDispatch callback when watchRunsInk is called;
    // return detached=true so the main loop exits after first watch
    mockWatchRunsInk.mockImplementation(
      async (_store: unknown, _runIds: unknown, opts: { autoDispatch?: () => Promise<string[]> }) => {
        capturedAutoDispatch = opts?.autoDispatch;
        return { detached: true };
      },
    );

    // 1st dispatch returns a task → watchRunsInk captures callback and returns detached=true
    mockDispatch.mockResolvedValueOnce({
      dispatched: [
        { seedId: "s-4", runId: "run-444", title: "Task 4", model: "claude-sonnet-4-6", worktreePath: "/tmp/wt", branchName: "foreman/s-4", runtime: "claude-code" },
      ],
      skipped: [],
      activeAgents: 1,
    });

    await invokeRun([]);

    expect(capturedAutoDispatch).toBeDefined();

    // Now invoke the captured callback — it should call dispatcher.dispatch
    mockDispatch.mockResolvedValueOnce({
      dispatched: [
        { seedId: "s-5", runId: "run-555", title: "Task 5", model: "claude-sonnet-4-6", worktreePath: "/tmp/wt", branchName: "foreman/s-5", runtime: "claude-code" },
      ],
      skipped: [],
      activeAgents: 1,
    });

    const newRunIds = await capturedAutoDispatch!();

    // Should return the run IDs of newly dispatched tasks
    expect(newRunIds).toEqual(["run-555"]);
    // dispatch called once by main loop + once by auto-dispatch callback = 2 total
    expect(mockDispatch).toHaveBeenCalledTimes(2);
  });

  it("passes autoDispatch in the 'waiting for active agents' watch path too", async () => {
    const activeRunIds = ["run-aaa", "run-bbb"];

    // First call: nothing dispatched but 2 active agents → watchRunsInk (returns detached=true to exit)
    mockDispatch.mockResolvedValueOnce({ dispatched: [], skipped: [], activeAgents: 2 });

    mockGetActiveRuns.mockReturnValue([
      { id: "run-aaa", status: "running" },
      { id: "run-bbb", status: "running" },
    ]);

    // Return detached=true so the loop exits after watching agents (no 2nd dispatch)
    mockWatchRunsInk.mockResolvedValue({ detached: true });

    await invokeRun([]);

    // watchRunsInk should be called with autoDispatch in the waiting-for-agents path
    expect(mockWatchRunsInk).toHaveBeenCalledWith(
      expect.anything(),
      activeRunIds,
      expect.objectContaining({ autoDispatch: expect.any(Function) }),
    );
  });
});
