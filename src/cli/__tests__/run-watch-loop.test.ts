/**
 * Tests for the dispatch loop watch-and-continue behavior.
 *
 * Verifies:
 * - When nothing is dispatched AND active agents exist AND watch=true:
 *   watchRunsInk is called with active run IDs, then the loop continues.
 * - When nothing is dispatched AND no active agents AND watch=true:
 *   loop polls (waits monitorPollMs) then retries dispatch instead of exiting.
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
      this.getProjectByPath = mockGetProjectByPath;
    });
    mockWatchRunsInk.mockResolvedValue({ detached: false });
    mockGetActiveRuns.mockReturnValue([]);
    mockGetProjectByPath.mockReturnValue(null);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  // ── Scenario 1: nothing dispatched, agents active, watch=true ───────────────

  it("waits for active agents then re-dispatches when watch=true and activeAgents > 0", async () => {
    const activeRunIds = ["run-aaa", "run-bbb"];

    // 1st dispatch: nothing dispatched, 2 active agents → watch them via watchRunsInk
    // 2nd dispatch (after agents finish): still nothing, 1 agent active → watchRunsInk again
    //   returns detached=true on 2nd call to cleanly exit the loop
    mockDispatch
      .mockResolvedValueOnce({ dispatched: [], skipped: [], activeAgents: 2 })
      .mockResolvedValueOnce({ dispatched: [], skipped: [], activeAgents: 1 });

    mockGetActiveRuns.mockReturnValue([
      { id: "run-aaa", status: "running" },
      { id: "run-bbb", status: "running" },
    ]);

    // 1st watchRunsInk returns detached=false → loop continues
    // 2nd watchRunsInk returns detached=true → loop exits
    mockWatchRunsInk
      .mockResolvedValueOnce({ detached: false })
      .mockResolvedValueOnce({ detached: true });

    await invokeRun([]);  // watch=true by default (--no-watch disables it)

    // watchRunsInk should have been called with the active run IDs from getActiveRuns
    expect(mockWatchRunsInk).toHaveBeenCalledWith(
      expect.anything(),   // store instance
      activeRunIds,
      expect.objectContaining({ notificationBus: expect.anything() }),
    );

    // dispatch should have been called twice (first iteration + re-check after first watch)
    expect(mockDispatch).toHaveBeenCalledTimes(2);
    // watchRunsInk called twice (once per dispatch that found active agents)
    expect(mockWatchRunsInk).toHaveBeenCalledTimes(2);
  });

  // ── Scenario 2: nothing dispatched, no active agents, watch=true ────────────
  // In watch mode, instead of exiting the loop polls for new ready tasks.

  it("polls for new tasks when watch=true, nothing dispatched, and no active agents", async () => {
    vi.useFakeTimers();

    // 1st dispatch: no tasks, no agents → should wait then retry
    // 2nd dispatch: a task becomes ready → dispatch it
    // 3rd dispatch: after the watch completes, nothing left → but we need to break
    //   so watchRunsInk returns detached=true to exit
    mockDispatch
      .mockResolvedValueOnce({ dispatched: [], skipped: [], activeAgents: 0 })
      .mockResolvedValueOnce({
        dispatched: [
          { seedId: "s-new", runId: "run-new", title: "Newly Ready Task", model: "claude-sonnet-4-6", worktreePath: "/tmp/wt", branchName: "foreman/s-new", runtime: "claude-code" },
        ],
        skipped: [],
        activeAgents: 1,
      });
    mockGetActiveRuns.mockReturnValue([]);

    // After dispatching the new task, watchRunsInk returns detached=true (user Ctrl+C)
    mockWatchRunsInk.mockResolvedValue({ detached: true });

    // Run command but advance the fake timers to let the poll sleep resolve
    const runPromise = invokeRun([]);
    // Let first dispatch resolve, then advance the timer to trigger the poll sleep
    await vi.runAllTimersAsync();
    await runPromise;

    // dispatch should have been called twice: initial empty → poll finds task
    expect(mockDispatch).toHaveBeenCalledTimes(2);

    // watchRunsInk called once for the newly-dispatched task
    expect(mockWatchRunsInk).toHaveBeenCalledTimes(1);
    expect(mockWatchRunsInk).toHaveBeenCalledWith(
      expect.anything(),
      ["run-new"],
      expect.objectContaining({ notificationBus: expect.anything() }),
    );

    vi.useRealTimers();
  });

  // ── Scenario 2b: "No ready tasks" message only logged once per wait period ───
  // Ensures we don't flood stdout with one log line every 3 seconds when waiting.

  it("logs 'No ready tasks' message only once across multiple poll iterations", async () => {
    vi.useFakeTimers();

    // 3 consecutive empty dispatches (no tasks, no agents) before a task appears
    mockDispatch
      .mockResolvedValueOnce({ dispatched: [], skipped: [], activeAgents: 0 })
      .mockResolvedValueOnce({ dispatched: [], skipped: [], activeAgents: 0 })
      .mockResolvedValueOnce({ dispatched: [], skipped: [], activeAgents: 0 })
      .mockResolvedValueOnce({
        dispatched: [
          { seedId: "s-late", runId: "run-late", title: "Late Task", model: "claude-sonnet-4-6", worktreePath: "/tmp/wt", branchName: "foreman/s-late", runtime: "claude-code" },
        ],
        skipped: [],
        activeAgents: 1,
      });
    mockGetActiveRuns.mockReturnValue([]);

    // Exit after the task is dispatched
    mockWatchRunsInk.mockResolvedValue({ detached: true });

    const runPromise = invokeRun([]);
    await vi.runAllTimersAsync();
    await runPromise;

    // beforeEach already installed a console.log spy — use it to count waiting messages.
    // The "No ready tasks" message should appear exactly once, not once per poll iteration.
    const consoleMock = vi.mocked(console.log);
    const waitingMessages = consoleMock.mock.calls.filter(
      (args) => typeof args[0] === "string" && String(args[0]).includes("No ready tasks")
    );
    expect(waitingMessages).toHaveLength(1);

    // dispatch should have been called 4 times (3 empty + 1 with task)
    expect(mockDispatch).toHaveBeenCalledTimes(4);

    vi.useRealTimers();
  });

  it("exits immediately when --no-watch and nothing dispatched and no active agents", async () => {
    mockDispatch.mockResolvedValue({ dispatched: [], skipped: [], activeAgents: 0 });
    mockGetActiveRuns.mockReturnValue([]);

    await invokeRun(["--no-watch"]);

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
    // Dispatch 1 task; after watch completes user detaches (Ctrl+C) to exit cleanly
    // (without detaching, the loop would continue polling for new tasks in watch mode)
    mockDispatch.mockResolvedValueOnce({
      dispatched: [
        { seedId: "s-1", runId: "run-111", title: "Task 1", model: "claude-sonnet-4-6", worktreePath: "/tmp/wt", branchName: "foreman/s-1", runtime: "claude-code" },
      ],
      skipped: [],
      activeAgents: 1,
    });

    // Return detached=true so the loop exits after first watch without looping back
    mockWatchRunsInk.mockResolvedValue({ detached: true });

    await invokeRun([]);

    // watchRunsInk should have been called with the dispatched run IDs
    expect(mockWatchRunsInk).toHaveBeenCalledWith(
      expect.anything(),
      ["run-111"],
      expect.objectContaining({ notificationBus: expect.anything() }),
    );

    // getActiveRuns should NOT have been called (normal dispatch path uses dispatched IDs)
    expect(mockGetActiveRuns).not.toHaveBeenCalled();
    // dispatch called once — detached before looping back
    expect(mockDispatch).toHaveBeenCalledTimes(1);
  });
});
