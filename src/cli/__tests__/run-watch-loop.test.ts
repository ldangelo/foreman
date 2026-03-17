/**
 * Tests for the dispatch loop watch-and-continue behavior.
 *
 * Verifies:
 * - When nothing is dispatched AND active agents exist AND watch=true:
 *   watchRunsInk is called with active run IDs, then the loop continues.
 * - When nothing is dispatched AND no active agents: loop exits immediately.
 * - When nothing is dispatched AND watch=false (--no-watch): loop exits immediately.
 * - dryRun always exits immediately.
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
  const MockForemanStore = vi.fn(function (this: Record<string, unknown>) {
    this.close = vi.fn();
    this.getActiveRuns = mockGetActiveRuns;
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

// ── Module under test ─────────────────────────────────────────────────────────
import { runCommand } from "../commands/run.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

/** Run the `run` command with given args. */
async function invokeRun(args: string[]): Promise<void> {
  await runCommand.parseAsync(args, { from: "user" });
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("dispatch loop: watch-and-continue when nothing dispatched but agents active", () => {
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
    });
    mockWatchRunsInk.mockResolvedValue({ detached: false });
    mockGetActiveRuns.mockReturnValue([]);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  // ── Scenario 1: nothing dispatched, agents active, watch=true ───────────────

  it("waits for active agents then re-dispatches when watch=true and activeAgents > 0", async () => {
    const activeRunIds = ["run-aaa", "run-bbb"];

    // First call: nothing dispatched but 2 active agents
    // Second call: still nothing dispatched, no active agents -> exit
    mockDispatch
      .mockResolvedValueOnce({ dispatched: [], skipped: [], activeAgents: 2 })
      .mockResolvedValueOnce({ dispatched: [], skipped: [], activeAgents: 0 });

    mockGetActiveRuns.mockReturnValue([
      { id: "run-aaa", status: "running" },
      { id: "run-bbb", status: "running" },
    ]);

    await invokeRun([]);  // watch=true by default (--no-watch disables it)

    // watchRunsInk should have been called with the active run IDs
    expect(mockWatchRunsInk).toHaveBeenCalledTimes(1);
    expect(mockWatchRunsInk).toHaveBeenCalledWith(
      expect.anything(),   // store instance
      activeRunIds,
      expect.objectContaining({ notificationBus: expect.anything() }),
    );

    // dispatch should have been called twice (first iteration + re-check after watch)
    expect(mockDispatch).toHaveBeenCalledTimes(2);
  });

  // ── Scenario 2: nothing dispatched, no active agents ────────────────────────

  it("exits immediately when nothing dispatched and no active agents", async () => {
    mockDispatch.mockResolvedValue({ dispatched: [], skipped: [], activeAgents: 0 });
    mockGetActiveRuns.mockReturnValue([]);

    await invokeRun([]);

    // watchRunsInk should NOT have been called — nothing to watch
    expect(mockWatchRunsInk).not.toHaveBeenCalled();

    // dispatch should have been called exactly once
    expect(mockDispatch).toHaveBeenCalledTimes(1);
  });

  // ── Scenario 3: nothing dispatched, agents active, --no-watch ───────────────

  it("exits immediately with --no-watch even if active agents are running", async () => {
    mockDispatch.mockResolvedValue({ dispatched: [], skipped: [], activeAgents: 3 });
    mockGetActiveRuns.mockReturnValue([
      { id: "run-ccc", status: "running" },
    ]);

    await invokeRun(["--no-watch"]);

    // watchRunsInk should NOT be called in no-watch mode
    expect(mockWatchRunsInk).not.toHaveBeenCalled();

    // dispatch called once, then loop exits
    expect(mockDispatch).toHaveBeenCalledTimes(1);
  });

  // ── Scenario 4: dry-run always exits immediately ─────────────────────────────

  it("exits immediately on --dry-run regardless of activeAgents", async () => {
    mockDispatch.mockResolvedValue({ dispatched: [], skipped: [], activeAgents: 5 });

    await invokeRun(["--dry-run"]);

    expect(mockWatchRunsInk).not.toHaveBeenCalled();
    expect(mockDispatch).toHaveBeenCalledTimes(1);
  });

  // ── Scenario 5: user detaches (Ctrl+C) during the wait ───────────────────────

  it("exits loop when user detaches (watchRunsInk returns detached=true) while waiting for active agents", async () => {
    mockDispatch.mockResolvedValue({ dispatched: [], skipped: [], activeAgents: 2 });
    mockGetActiveRuns.mockReturnValue([
      { id: "run-ddd", status: "running" },
    ]);
    // Simulate user pressing Ctrl+C
    mockWatchRunsInk.mockResolvedValue({ detached: true });

    await invokeRun([]);

    // watchRunsInk called once, then we break out
    expect(mockWatchRunsInk).toHaveBeenCalledTimes(1);
    // dispatch called only once — we don't re-check after detach
    expect(mockDispatch).toHaveBeenCalledTimes(1);
  });

  // ── Scenario 6: normal dispatch + watch loop remains unchanged ───────────────

  it("watches dispatched run IDs (not getActiveRuns) when tasks were dispatched", async () => {
    // First call: dispatch 1 task; second call: nothing dispatched, no active agents
    mockDispatch
      .mockResolvedValueOnce({
        dispatched: [
          { seedId: "s-1", runId: "run-111", title: "Task 1", model: "claude-sonnet-4-6", worktreePath: "/tmp/wt", branchName: "foreman/s-1", runtime: "claude-code" },
        ],
        skipped: [],
        activeAgents: 1,
      })
      .mockResolvedValueOnce({ dispatched: [], skipped: [], activeAgents: 0 });

    await invokeRun([]);

    // watchRunsInk should have been called with the dispatched run IDs
    expect(mockWatchRunsInk).toHaveBeenCalledWith(
      expect.anything(),
      ["run-111"],
      expect.objectContaining({ notificationBus: expect.anything() }),
    );

    // getActiveRuns should NOT have been called (normal dispatch path)
    expect(mockGetActiveRuns).not.toHaveBeenCalled();
    expect(mockDispatch).toHaveBeenCalledTimes(2);
  });
});
