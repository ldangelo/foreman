/**
 * Integration characterization tests for Dispatcher — native task store path.
 *
 * These tests document the native-only task store behavior as a characterization
 * suite. They are excluded from the normal test suite (vitest.integration.config.ts)
 * because they were originally written against the SQLite-based ForemanStore which
 * has been disabled in favor of native Postgres-only operation.
 *
 * The tests here use mocks to verify the dispatcher's behavior when interacting
 * with native task store operations, without depending on a live database.
 *
 * TRD-007 / REQ-017 characterization: documents that the dispatcher exclusively
 * uses the native Postgres task store (no beads/br fallback path exists).
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { Dispatcher } from "../dispatcher.js";
import type { ITaskClient, Issue } from "../../lib/task-client.js";
import type { ForemanStore, NativeTask } from "../../lib/store.js";

// ── Module mocks ─────────────────────────────────────────────────────────

vi.mock("../../lib/vcs/git-backend.js", () => ({
  GitBackend: vi.fn().mockImplementation(() => ({
    getCurrentBranch: vi.fn().mockResolvedValue("main"),
    detectDefaultBranch: vi.fn().mockResolvedValue("main"),
    createWorkspace: vi.fn().mockResolvedValue({
      workspacePath: "/tmp/mock-worktree",
      branchName: "foreman/t-001",
    }),
  })),
}));

vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: vi.fn().mockResolvedValue({
      name: "git",
      getCurrentBranch: vi.fn().mockResolvedValue("main"),
      detectDefaultBranch: vi.fn().mockResolvedValue("main"),
      createWorkspace: vi.fn().mockResolvedValue({
        workspacePath: "/tmp/mock-worktree",
        branchName: "foreman/mock",
      }),
    }),
    resolveBackend: vi.fn(() => "git"),
  },
}));

vi.mock("../../lib/worktree-manager.js", () => ({
  WorktreeManager: class {
    async createWorktree(opts: { projectId: string; beadId: string; repoPath: string; baseBranch?: string }) {
      return {
        projectId: opts.projectId,
        beadId: opts.beadId,
        branchName: `foreman/${opts.beadId}`,
        path: `/tmp/worktrees/${opts.projectId}/${opts.beadId}`,
        exists: false,
      };
    }
  },
}));

vi.mock("../../lib/setup.js", () => ({
  installDependencies: vi.fn().mockResolvedValue(undefined),
  runSetupWithCache: vi.fn().mockResolvedValue(undefined),
  runWorkspaceHook: vi.fn().mockResolvedValue(undefined),
}));

vi.mock("node:fs/promises", async (importOriginal) => {
  const orig = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...orig,
    writeFile: vi.fn().mockResolvedValue(undefined),
    mkdir: vi.fn().mockResolvedValue(undefined),
    open: vi.fn().mockResolvedValue({ fd: 3, close: vi.fn() }),
    readdir: vi.fn().mockResolvedValue([]),
    unlink: vi.fn().mockResolvedValue(undefined),
  };
});

vi.mock("../../lib/workflow-loader.js", () => ({
  loadWorkflowConfig: vi.fn().mockReturnValue({ setup: [], setupCache: undefined, vcs: undefined }),
  resolveWorkflowName: vi.fn().mockReturnValue("default"),
}));

vi.mock("../../lib/project-config.js", () => ({
  loadProjectConfig: vi.fn().mockReturnValue(null),
  resolveVcsConfig: vi.fn().mockReturnValue({ backend: "git" }),
}));

vi.mock("../templates.js", () => ({
  workerAgentMd: vi.fn().mockReturnValue("# Mock TASK.md\n"),
}));

vi.mock("../pi-sdk-runner.js", () => ({
  runWithPiSdk: vi.fn().mockResolvedValue({ sessionKey: "mock-session" }),
}));

vi.mock("../../lib/workflow-config-loader.js", () => ({
  resolveWorkflowType: vi.fn().mockReturnValue("feature"),
}));

// ── Test fixtures ────────────────────────────────────────────────────────

function makeNativeTask(id: string, priority = 2): NativeTask {
  return {
    id,
    title: `Native task ${id}`,
    description: null,
    type: "task",
    priority,
    status: "ready",
    run_id: null,
    branch: null,
    external_id: null,
    created_at: "2024-01-01T00:00:00.000Z",
    updated_at: "2024-01-01T00:00:00.000Z",
    approved_at: null,
    closed_at: null,
  };
}

function makeMockBeadsClient(): ITaskClient {
  return {
    ready: vi.fn().mockResolvedValue([]),
    show: vi.fn().mockResolvedValue({ status: "open" }),
    update: vi.fn().mockResolvedValue(undefined),
    close: vi.fn().mockResolvedValue(undefined),
    list: vi.fn().mockResolvedValue([]),
  };
}

function makeMockStore(opts: {
  hasNativeTasks?: boolean;
  nativeTasks?: NativeTask[];
  claimResult?: boolean;
} = {}): ForemanStore {
  return {
    getActiveRuns: vi.fn().mockReturnValue([]),
    getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
    getRunsForSeed: vi.fn().mockReturnValue([]),
    getRunsByStatus: vi.fn().mockReturnValue([]),
    getRunsByStatuses: vi.fn().mockReturnValue([]),
    getStuckRunsForSeed: vi.fn().mockReturnValue([]),
    hasActiveOrPendingRun: vi.fn().mockReturnValue(false),
    hasNativeTasks: vi.fn().mockReturnValue(opts.hasNativeTasks ?? false),
    getReadyTasks: vi.fn().mockReturnValue(opts.nativeTasks ?? []),
    getTaskByExternalId: vi.fn().mockReturnValue(null),
    getTaskById: vi.fn().mockReturnValue(null),
    claimTask: vi.fn().mockReturnValue(opts.claimResult ?? true),
    createRun: vi.fn().mockReturnValue({
      id: "run-001",
      project_id: "proj-1",
      seed_id: "",
      status: "pending",
      created_at: new Date().toISOString(),
    }),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    sendMessage: vi.fn(),
  } as unknown as ForemanStore;
}

// ── Characterization: native-only dispatch ───────────────────────────────

/**
 * Characterization: the dispatcher reads ready tasks exclusively from the native
 * task store (ForemanStore.getReadyTasks). No beads/br fallback path exists.
 *
 * This test documents that native tasks are the only seed source.
 */
describe("Dispatcher — native task store is the sole seed source (characterization)", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("dispatches native tasks via dry-run without querying beads client", async () => {
    const nativeTasks = [makeNativeTask("t-native-001"), makeNativeTask("t-native-002")];
    const store = makeMockStore({ hasNativeTasks: true, nativeTasks });
    const beadsClient = makeMockBeadsClient();

    const dispatcher = new Dispatcher(beadsClient, store, "/tmp");
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const result = await dispatcher.dispatch({ dryRun: true });

    consoleSpy.mockRestore();

    // Native tasks should be dispatched
    expect(result.dispatched.map((d) => d.seedId)).toContain("t-native-001");
    expect(result.dispatched.map((d) => d.seedId)).toContain("t-native-002");

    // Beads client must NOT be called — native is the only path
    expect(beadsClient.ready).not.toHaveBeenCalled();
    expect(beadsClient.show).not.toHaveBeenCalled();

    // Native store must be queried
    expect(store.getReadyTasks).toHaveBeenCalled();
  });

  it("returns zero dispatches when native task store has no ready tasks", async () => {
    const store = makeMockStore({ hasNativeTasks: true, nativeTasks: [] });
    const beadsClient = makeMockBeadsClient();

    const dispatcher = new Dispatcher(beadsClient, store, "/tmp");
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const result = await dispatcher.dispatch({ dryRun: true });

    consoleSpy.mockRestore();

    // No tasks dispatched
    expect(result.dispatched).toHaveLength(0);
    // Beads NOT consulted
    expect(beadsClient.ready).not.toHaveBeenCalled();
  });

  it("skips tasks with active runs and does not query beads for those tasks", async () => {
    const task = makeNativeTask("t-active-001");
    const store = makeMockStore({ hasNativeTasks: true, nativeTasks: [task] });
    // Simulate an active run already exists for this task
    (store.getActiveRuns as ReturnType<typeof vi.fn>).mockReturnValue([
      {
        id: "run-existing",
        project_id: "proj-1",
        seed_id: "t-active-001",
        status: "running",
        created_at: new Date().toISOString(),
      },
    ]);
    const beadsClient = makeMockBeadsClient();

    const dispatcher = new Dispatcher(beadsClient, store, "/tmp");
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const result = await dispatcher.dispatch({ dryRun: true });

    consoleSpy.mockRestore();

    // Task should be skipped (already has active run)
    expect(result.skipped).toHaveLength(1);
    expect(result.skipped[0]!.reason).toMatch(/active run/i);
    // Beads still not called
    expect(beadsClient.ready).not.toHaveBeenCalled();
  });

  it("skips tasks with completed (unmerged) runs and does not query beads", async () => {
    const task = makeNativeTask("t-merged-001");
    const store = makeMockStore({ hasNativeTasks: true, nativeTasks: [task] });
    // Simulate a completed-but-unmerged run
    (store.getRunsByStatus as ReturnType<typeof vi.fn>).mockReturnValue([
      {
        id: "run-completed",
        project_id: "proj-1",
        seed_id: "t-merged-001",
        status: "completed",
        created_at: new Date().toISOString(),
      },
    ]);
    const beadsClient = makeMockBeadsClient();

    const dispatcher = new Dispatcher(beadsClient, store, "/tmp");
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const result = await dispatcher.dispatch({ dryRun: true });

    consoleSpy.mockRestore();

    // Task should be skipped (has completed run awaiting merge)
    expect(result.skipped).toHaveLength(1);
    expect(result.skipped[0]!.reason).toMatch(/merge/i);
    expect(beadsClient.ready).not.toHaveBeenCalled();
  });
});

// ── Characterization: atomic claim transaction ────────────────────────────

/**
 * Characterization: the dispatcher uses an atomic claim transaction against the
 * native task store when dispatching a task. The claim either succeeds (task
 * transitions ready→in-progress and is dispatched) or fails (task is already
 * claimed and the run record is rolled back).
 *
 * AC-017.2 / TRD-007.
 */
describe("Dispatcher — atomic claim against native task store (characterization)", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  function makeStoreWithRun(taskId: string, runId: string): ForemanStore {
    return {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      getRunsByStatuses: vi.fn().mockReturnValue([]),
      getStuckRunsForSeed: vi.fn().mockReturnValue([]),
      hasActiveOrPendingRun: vi.fn().mockReturnValue(false),
      hasNativeTasks: vi.fn().mockReturnValue(true),
      getReadyTasks: vi.fn().mockReturnValue([makeNativeTask(taskId)]),
      getTaskByExternalId: vi.fn().mockReturnValue(null),
      getTaskById: vi.fn().mockReturnValue(null),
      claimTask: vi.fn().mockReturnValue(true),
      createRun: vi.fn().mockReturnValue({
        id: runId,
        project_id: "proj-1",
        seed_id: taskId,
        status: "pending",
        created_at: new Date().toISOString(),
      }),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
      sendMessage: vi.fn(),
    } as unknown as ForemanStore;
  }

  it("calls claimTask(taskId, runId) on successful dispatch", async () => {
    const taskId = "t-claim-001";
    const runId = "run-claim-001";
    const store = makeStoreWithRun(taskId, runId);
    const beadsClient = makeMockBeadsClient();

    const dispatcher = new Dispatcher(beadsClient, store, "/tmp");
    const spawnSpy = vi
      .spyOn(dispatcher as unknown as { spawnAgent: () => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "mock-session" });
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const result = await dispatcher.dispatch({ dryRun: false });

    consoleSpy.mockRestore();

    // claimTask was called with taskId and runId
    expect(store.claimTask).toHaveBeenCalledTimes(1);
    expect(vi.mocked(store.claimTask).mock.calls[0]?.slice(0, 2)).toEqual([taskId, runId]);

    // Task was dispatched
    expect(result.dispatched).toHaveLength(1);
    expect(result.dispatched[0]!.seedId).toBe(taskId);
    expect(result.dispatched[0]!.runId).toBe(runId);

    spawnSpy.mockRestore();
  });

  it("rolls back orphaned run when claimTask returns false (double-dispatch prevention)", async () => {
    const taskId = "t-race-001";
    const runId = "run-race-001";
    const store = makeStoreWithRun(taskId, runId);
    // Simulate race: another dispatcher already claimed the task
    (store.claimTask as ReturnType<typeof vi.fn>).mockReturnValue(false);
    const beadsClient = makeMockBeadsClient();

    const dispatcher = new Dispatcher(beadsClient, store, "/tmp");
    const spawnSpy = vi
      .spyOn(dispatcher as unknown as { spawnAgent: () => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "mock-session" });
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const result = await dispatcher.dispatch({ dryRun: false });

    consoleSpy.mockRestore();

    // Task should NOT be dispatched
    expect(result.dispatched).toHaveLength(0);

    // Task should appear in skipped with a claim-related reason
    expect(result.skipped).toHaveLength(1);
    expect(result.skipped[0]!.reason).toMatch(/claim/i);

    // Orphaned run should be marked failed (rollback)
    expect(store.updateRun).toHaveBeenCalledWith(
      runId,
      expect.objectContaining({ status: "failed" }),
    );

    // spawnAgent must NOT have been called
    expect(spawnSpy).not.toHaveBeenCalled();

    spawnSpy.mockRestore();
  });
});

// ── Characterization: priority ordering ─────────────────────────────────

/**
 * Characterization: native tasks are dispatched in the order returned by
 * ForemanStore.getReadyTasks (P0 first, ascending numeric priority). The store
 * is responsible for sorting; the dispatcher preserves that order.
 */
describe("Dispatcher — native tasks dispatched in priority order (characterization)", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("dispatches P0 before P2 before P4 (ascending priority)", async () => {
    const tasks = [
      makeNativeTask("low-prio", 3),
      makeNativeTask("high-prio", 0),
      makeNativeTask("mid-prio", 2),
    ];
    const store = makeMockStore({ hasNativeTasks: true, nativeTasks: tasks });
    // getReadyTasks returns them in priority order (store sorts by priority ASC)
    (store.getReadyTasks as ReturnType<typeof vi.fn>).mockReturnValue([
      makeNativeTask("high-prio", 0),
      makeNativeTask("mid-prio", 2),
      makeNativeTask("low-prio", 3),
    ]);
    const beadsClient = makeMockBeadsClient();
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const dispatcher = new Dispatcher(beadsClient, store, "/tmp");
    const result = await dispatcher.dispatch({ dryRun: true });

    consoleSpy.mockRestore();

    const ids = result.dispatched.map((d) => d.seedId);
    expect(ids[0]).toBe("high-prio");
    expect(ids[1]).toBe("mid-prio");
    expect(ids[2]).toBe("low-prio");
  });
});
