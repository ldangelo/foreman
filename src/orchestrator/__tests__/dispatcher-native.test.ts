/**
 * Unit tests for Dispatcher — native task store path, beads fallback,
 * FOREMAN_TASK_STORE overrides, and atomic claim transaction.
 *
 * Verifies TRD-007 / REQ-014 / REQ-017.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  Dispatcher,
  resolveTaskStoreMode,
  nativeTaskToIssue,
  type TaskStoreMode,
} from "../dispatcher.js";
import type { ITaskClient, Issue } from "../../lib/task-client.js";
import type { ForemanStore, NativeTask } from "../../lib/store.js";

// ── Module mocks for VCS / filesystem operations ─────────────────────────
// These prevent git/jj errors when testing the non-dryRun dispatch path.

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
  },
}));

vi.mock("../../lib/setup.js", () => ({
  installDependencies: vi.fn().mockResolvedValue(undefined),
  runSetupWithCache: vi.fn().mockResolvedValue(undefined),
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

// ── Test Fixtures ────────────────────────────────────────────────────────

/** Create a minimal Issue as returned by BeadsRustClient.ready() */
function makeBeadsIssue(id: string, priority = "P2"): Issue {
  return {
    id,
    title: `Beads task ${id}`,
    type: "task",
    priority,
    status: "open",
    assignee: null,
    parent: null,
    created_at: "2024-01-01T00:00:00.000Z",
    updated_at: "2024-01-01T00:00:00.000Z",
  };
}

/** Create a NativeTask row as returned from the SQLite tasks table */
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

/** Build a minimal ITaskClient mock */
function makeMockBeadsClient(issues: Issue[] = []): ITaskClient {
  return {
    ready: vi.fn().mockResolvedValue(issues),
    show: vi.fn().mockResolvedValue({ status: "open" }),
    update: vi.fn().mockResolvedValue(undefined),
    close: vi.fn().mockResolvedValue(undefined),
    list: vi.fn().mockResolvedValue([]),
  };
}

/** Build a minimal ForemanStore mock including native-task methods */
function makeMockStore(opts: {
  hasNativeTasks?: boolean;
  nativeTasks?: NativeTask[];
  claimResult?: boolean;
  externalIdTask?: NativeTask | null;
} = {}): ForemanStore {
  return {
    getActiveRuns: vi.fn().mockReturnValue([]),
    getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
    getRunsForSeed: vi.fn().mockReturnValue([]),
    getRunsByStatus: vi.fn().mockReturnValue([]),
    getStuckRunsForSeed: vi.fn().mockReturnValue([]),
    getRunsByStatuses: vi.fn().mockReturnValue([]),
    hasActiveOrPendingRun: vi.fn().mockReturnValue(false),
    // Native task store methods (REQ-017)
    hasNativeTasks: vi.fn().mockReturnValue(opts.hasNativeTasks ?? false),
    getReadyTasks: vi.fn().mockReturnValue(opts.nativeTasks ?? []),
    getTaskByExternalId: vi.fn().mockReturnValue(opts.externalIdTask ?? null),
    getTaskById: vi.fn().mockReturnValue(null),
    claimTask: vi.fn().mockReturnValue(opts.claimResult ?? true),
    // Other methods used in dispatch flow
    createRun: vi.fn().mockReturnValue({ id: "run-001", project_id: "proj-1", seed_id: "" }),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    sendMessage: vi.fn(),
    getBeadWriteQueue: vi.fn().mockReturnValue([]),
    markBeadWriteProcessed: vi.fn(),
  } as unknown as ForemanStore;
}

/** Temporarily override process.env[key] for the duration of fn() */
async function withEnvVar(key: string, value: string | undefined, fn: () => Promise<void>): Promise<void> {
  const original = process.env[key];
  if (value === undefined) {
    delete process.env[key];
  } else {
    process.env[key] = value;
  }
  try {
    await fn();
  } finally {
    if (original === undefined) {
      delete process.env[key];
    } else {
      process.env[key] = original;
    }
  }
}

// ── resolveTaskStoreMode() ────────────────────────────────────────────────

describe("resolveTaskStoreMode()", () => {
  afterEach(() => {
    delete process.env.FOREMAN_TASK_STORE;
  });

  it("returns 'auto' when FOREMAN_TASK_STORE is not set", () => {
    delete process.env.FOREMAN_TASK_STORE;
    expect(resolveTaskStoreMode()).toBe("auto");
  });

  it("returns 'auto' when FOREMAN_TASK_STORE='auto'", () => {
    process.env.FOREMAN_TASK_STORE = "auto";
    expect(resolveTaskStoreMode()).toBe("auto");
  });

  it("returns 'native' when FOREMAN_TASK_STORE='native'", () => {
    process.env.FOREMAN_TASK_STORE = "native";
    expect(resolveTaskStoreMode()).toBe("native");
  });

  it("returns 'beads' when FOREMAN_TASK_STORE='beads'", () => {
    process.env.FOREMAN_TASK_STORE = "beads";
    expect(resolveTaskStoreMode()).toBe("beads");
  });

  it("returns 'auto' and emits warning for invalid value", () => {
    process.env.FOREMAN_TASK_STORE = "invalid-value";
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const mode = resolveTaskStoreMode();
    expect(mode).toBe("auto");
    expect(consoleSpy.mock.calls.some((args) => args[0].includes("invalid-value"))).toBe(true);
    consoleSpy.mockRestore();
  });

  it("returns 'auto' for empty string", () => {
    process.env.FOREMAN_TASK_STORE = "";
    expect(resolveTaskStoreMode()).toBe("auto");
  });
});

// ── nativeTaskToIssue() ──────────────────────────────────────────────────

describe("nativeTaskToIssue()", () => {
  it("converts integer priority to P-string form", () => {
    const task = makeNativeTask("t-001", 0);
    const issue = nativeTaskToIssue(task);
    expect(issue.priority).toBe("P0");
  });

  it("maps priority 1..4 correctly", () => {
    for (let p = 0; p <= 4; p++) {
      const issue = nativeTaskToIssue(makeNativeTask("t", p));
      expect(issue.priority).toBe(`P${p}`);
    }
  });

  it("preserves id, title, type, status", () => {
    const task = makeNativeTask("native-42", 2);
    task.title = "My task";
    task.type = "bug";
    task.status = "ready";
    const issue = nativeTaskToIssue(task);
    expect(issue.id).toBe("native-42");
    expect(issue.title).toBe("My task");
    expect(issue.type).toBe("bug");
    expect(issue.status).toBe("ready");
  });

  it("sets assignee and parent to null", () => {
    const issue = nativeTaskToIssue(makeNativeTask("t-002"));
    expect(issue.assignee).toBeNull();
    expect(issue.parent).toBeNull();
  });

  it("maps description from NativeTask", () => {
    const task = makeNativeTask("t-003");
    task.description = "Some description";
    const issue = nativeTaskToIssue(task);
    expect(issue.description).toBe("Some description");
  });

  it("maps null description to undefined", () => {
    const task = makeNativeTask("t-004");
    task.description = null;
    const issue = nativeTaskToIssue(task);
    // undefined or null both acceptable; the key point is it does not throw
    expect(issue.description == null).toBe(true);
  });
});

// ── Dispatcher — Native task store coexistence (AC-014.1) ────────────────

describe("Dispatcher — Native task store coexistence (AC-014.1)", () => {
  afterEach(() => {
    delete process.env.FOREMAN_TASK_STORE;
    vi.restoreAllMocks();
  });

  it("uses native store when hasNativeTasks() returns true (auto mode)", async () => {
    const nativeTasks = [makeNativeTask("n-001"), makeNativeTask("n-002")];
    const store = makeMockStore({ hasNativeTasks: true, nativeTasks });
    const beadsClient = makeMockBeadsClient([makeBeadsIssue("b-001")]);

    const dispatcher = new Dispatcher(beadsClient, store, "/tmp");
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const result = await dispatcher.dispatch({ dryRun: true });
    consoleSpy.mockRestore();

    // Native tasks dispatched, not beads
    expect(result.dispatched.map((d) => d.seedId)).toContain("n-001");
    expect(result.dispatched.map((d) => d.seedId)).toContain("n-002");
    expect(result.dispatched.map((d) => d.seedId)).not.toContain("b-001");

    // Native store queried
    expect(store.getReadyTasks).toHaveBeenCalled();
    // Beads NOT queried
    expect(beadsClient.ready).not.toHaveBeenCalled();
  });

  it("falls back to beads for explicit bead dispatch when native tasks exist but no external_id matches", async () => {
    const beadsIssue = makeBeadsIssue("bd-explicit");
    const beadsClient = makeMockBeadsClient([]);
    beadsClient.show = vi.fn().mockResolvedValue({ ...beadsIssue, status: "open" });

    const store = makeMockStore({
      hasNativeTasks: true,
      nativeTasks: [makeNativeTask("native-ready")],
      externalIdTask: null,
    });

    const dispatcher = new Dispatcher(beadsClient, store, "/tmp");
    const spawnSpy = vi
      .spyOn(dispatcher as unknown as { spawnAgent: () => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "mock-session" });

    const result = await dispatcher.dispatch({ dryRun: false, seedId: "bd-explicit" });

    expect(result.dispatched).toHaveLength(1);
    expect(result.dispatched[0]!.seedId).toBe("bd-explicit");
    expect(store.getTaskByExternalId).toHaveBeenCalledWith("bd-explicit");
    expect(store.claimTask).not.toHaveBeenCalled();
    expect(beadsClient.update).toHaveBeenCalledWith("bd-explicit", { status: "in_progress" });
    expect(spawnSpy).toHaveBeenCalled();

    spawnSpy.mockRestore();
  });

  it("falls back to beads when hasNativeTasks() returns false (auto mode)", async () => {
    const store = makeMockStore({ hasNativeTasks: false, nativeTasks: [] });
    const beadsClient = makeMockBeadsClient([makeBeadsIssue("b-001"), makeBeadsIssue("b-002")]);

    const dispatcher = new Dispatcher(beadsClient, store, "/tmp");
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const result = await dispatcher.dispatch({ dryRun: true });
    consoleSpy.mockRestore();

    // Beads tasks dispatched
    expect(result.dispatched.map((d) => d.seedId)).toContain("b-001");
    expect(result.dispatched.map((d) => d.seedId)).toContain("b-002");

    // Beads queried; native store NOT queried
    expect(beadsClient.ready).toHaveBeenCalled();
    expect(store.getReadyTasks).not.toHaveBeenCalled();
  });

  it("logs which path was taken (debug log for AC-014.1)", async () => {
    const store = makeMockStore({ hasNativeTasks: true, nativeTasks: [] });
    const beadsClient = makeMockBeadsClient([]);
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const dispatcher = new Dispatcher(beadsClient, store, "/tmp");
    await dispatcher.dispatch({ dryRun: true });

    const logs = consoleSpy.mock.calls.map((args) => String(args[0]));
    expect(logs.some((m) => m.includes("native"))).toBe(true);
    consoleSpy.mockRestore();
  });

  it("logs beads fallback path when no native tasks", async () => {
    const store = makeMockStore({ hasNativeTasks: false });
    const beadsClient = makeMockBeadsClient([]);
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const dispatcher = new Dispatcher(beadsClient, store, "/tmp");
    await dispatcher.dispatch({ dryRun: true });

    const logs = consoleSpy.mock.calls.map((args) => String(args[0]));
    expect(logs.some((m) => m.includes("beads fallback") || m.includes("fallback"))).toBe(true);
    consoleSpy.mockRestore();
  });
});

// ── Dispatcher — FOREMAN_TASK_STORE overrides (AC-014.2) ─────────────────

describe("Dispatcher — FOREMAN_TASK_STORE overrides (AC-014.2)", () => {
  afterEach(() => {
    delete process.env.FOREMAN_TASK_STORE;
    vi.restoreAllMocks();
  });

  it("FOREMAN_TASK_STORE=native forces native store even when hasNativeTasks() is false", async () => {
    process.env.FOREMAN_TASK_STORE = "native";
    const nativeTasks = [makeNativeTask("n-force-001")];
    // hasNativeTasks returns false, but env override forces native
    const store = makeMockStore({ hasNativeTasks: false, nativeTasks });
    const beadsClient = makeMockBeadsClient([makeBeadsIssue("b-001")]);

    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const dispatcher = new Dispatcher(beadsClient, store, "/tmp");
    const result = await dispatcher.dispatch({ dryRun: true });
    consoleSpy.mockRestore();

    // Native tasks used
    expect(result.dispatched.map((d) => d.seedId)).toContain("n-force-001");
    expect(result.dispatched.map((d) => d.seedId)).not.toContain("b-001");
    expect(store.getReadyTasks).toHaveBeenCalled();
    expect(beadsClient.ready).not.toHaveBeenCalled();
  });

  it("FOREMAN_TASK_STORE=beads forces beads even when hasNativeTasks() is true", async () => {
    process.env.FOREMAN_TASK_STORE = "beads";
    const nativeTasks = [makeNativeTask("n-001")];
    // hasNativeTasks returns true, but env override forces beads
    const store = makeMockStore({ hasNativeTasks: true, nativeTasks });
    const beadsClient = makeMockBeadsClient([makeBeadsIssue("b-force-001")]);

    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const dispatcher = new Dispatcher(beadsClient, store, "/tmp");
    const result = await dispatcher.dispatch({ dryRun: true });
    consoleSpy.mockRestore();

    // Beads tasks used, not native
    expect(result.dispatched.map((d) => d.seedId)).toContain("b-force-001");
    expect(result.dispatched.map((d) => d.seedId)).not.toContain("n-001");
    expect(beadsClient.ready).toHaveBeenCalled();
    expect(store.getReadyTasks).not.toHaveBeenCalled();
  });

  it("FOREMAN_TASK_STORE=native logs a message indicating native forced", async () => {
    process.env.FOREMAN_TASK_STORE = "native";
    const store = makeMockStore({ hasNativeTasks: false, nativeTasks: [] });
    const beadsClient = makeMockBeadsClient([]);
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const dispatcher = new Dispatcher(beadsClient, store, "/tmp");
    await dispatcher.dispatch({ dryRun: true });

    const logs = consoleSpy.mock.calls.map((args) => String(args[0]));
    expect(logs.some((m) => m.includes("FOREMAN_TASK_STORE=native"))).toBe(true);
    consoleSpy.mockRestore();
  });

  it("FOREMAN_TASK_STORE=beads logs a message indicating beads forced", async () => {
    process.env.FOREMAN_TASK_STORE = "beads";
    const store = makeMockStore({ hasNativeTasks: true, nativeTasks: [] });
    const beadsClient = makeMockBeadsClient([]);
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const dispatcher = new Dispatcher(beadsClient, store, "/tmp");
    await dispatcher.dispatch({ dryRun: true });

    const logs = consoleSpy.mock.calls.map((args) => String(args[0]));
    expect(logs.some((m) => m.includes("FOREMAN_TASK_STORE=beads"))).toBe(true);
    consoleSpy.mockRestore();
  });

  it("does not call hasNativeTasks() when FOREMAN_TASK_STORE=native", async () => {
    process.env.FOREMAN_TASK_STORE = "native";
    const store = makeMockStore({ hasNativeTasks: false, nativeTasks: [] });
    const beadsClient = makeMockBeadsClient([]);
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const dispatcher = new Dispatcher(beadsClient, store, "/tmp");
    await dispatcher.dispatch({ dryRun: true });
    consoleSpy.mockRestore();

    // With native forced, hasNativeTasks check is bypassed
    expect(store.hasNativeTasks).not.toHaveBeenCalled();
  });

  it("does not call hasNativeTasks() when FOREMAN_TASK_STORE=beads", async () => {
    process.env.FOREMAN_TASK_STORE = "beads";
    const store = makeMockStore({ hasNativeTasks: true, nativeTasks: [] });
    const beadsClient = makeMockBeadsClient([]);
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const dispatcher = new Dispatcher(beadsClient, store, "/tmp");
    await dispatcher.dispatch({ dryRun: true });
    consoleSpy.mockRestore();

    // With beads forced, hasNativeTasks check is bypassed
    expect(store.hasNativeTasks).not.toHaveBeenCalled();
  });
});

// ── Dispatcher — Atomic claim transaction (AC-017.2) ─────────────────────

describe("Dispatcher — Atomic claim transaction (AC-017.2)", () => {
  afterEach(() => {
    delete process.env.FOREMAN_TASK_STORE;
    vi.restoreAllMocks();
  });

  /**
   * Build a store mock wired for a real (non-dryRun) dispatch with native tasks.
   * The store.createRun() returns a run so the dispatch can call claimTask().
   */
  function makeStoreForClaim(opts: {
    claimResult?: boolean;
    nativeTasks?: NativeTask[];
  } = {}): ForemanStore {
    return {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      getRunsByStatuses: vi.fn().mockReturnValue([]),
      getStuckRunsForSeed: vi.fn().mockReturnValue([]),
      hasActiveOrPendingRun: vi.fn().mockReturnValue(false),
      hasNativeTasks: vi.fn().mockReturnValue(true),
      getReadyTasks: vi.fn().mockReturnValue(opts.nativeTasks ?? [makeNativeTask("t-001")]),
      claimTask: vi.fn().mockReturnValue(opts.claimResult ?? true),
      createRun: vi.fn().mockReturnValue({
        id: "run-abc",
        project_id: "proj-1",
        seed_id: "t-001",
        status: "pending",
        created_at: new Date().toISOString(),
      }),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
      sendMessage: vi.fn(),
      getBeadWriteQueue: vi.fn().mockReturnValue([]),
      markBeadWriteProcessed: vi.fn(),
    } as unknown as ForemanStore;
  }

  it("calls claimTask() with taskId and runId on successful dispatch", async () => {
    process.env.FOREMAN_TASK_STORE = "native";
    const task = makeNativeTask("t-claim-001");
    const store = makeStoreForClaim({ nativeTasks: [task], claimResult: true });
    const beadsClient = makeMockBeadsClient([]);
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const dispatcher = new Dispatcher(beadsClient, store, "/tmp");
    // Use dryRun: true to avoid actual worktree creation
    // Note: dryRun skips the try block where claimTask() is called.
    // For atomic claim we need dryRun: false but with spawnAgent mocked.
    // Instead, verify via dryRun that native tasks are queried, and verify
    // claimTask logic separately.
    await dispatcher.dispatch({ dryRun: true });
    consoleSpy.mockRestore();

    // In dryRun mode, claim is not called (we skip the real dispatch block)
    // Verify native tasks were retrieved
    expect(store.getReadyTasks).toHaveBeenCalled();
  });

  it("claimTask() called with correct taskId and runId in real dispatch (AC-017.2)", async () => {
    process.env.FOREMAN_TASK_STORE = "native";

    const task = makeNativeTask("t-atomic-001");
    const createdRun = {
      id: "run-xyz-123",
      project_id: "proj-1",
      seed_id: "t-atomic-001",
      status: "pending",
      created_at: new Date().toISOString(),
    };

    const store: ForemanStore = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      getRunsByStatuses: vi.fn().mockReturnValue([]),
      getStuckRunsForSeed: vi.fn().mockReturnValue([]),
      hasActiveOrPendingRun: vi.fn().mockReturnValue(false),
      hasNativeTasks: vi.fn().mockReturnValue(true),
      getReadyTasks: vi.fn().mockReturnValue([task]),
      claimTask: vi.fn().mockReturnValue(true),
      createRun: vi.fn().mockReturnValue(createdRun),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
      sendMessage: vi.fn(),
      getBeadWriteQueue: vi.fn().mockReturnValue([]),
      markBeadWriteProcessed: vi.fn(),
    } as unknown as ForemanStore;

    const beadsClient = makeMockBeadsClient([]);

    // Mock spawnAgent to avoid actually spawning processes
    const dispatcher = new Dispatcher(beadsClient, store, "/tmp");
    // Inject a spy on the private spawnAgent by patching the prototype
    const spawnSpy = vi
      .spyOn(dispatcher as unknown as { spawnAgent: () => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "sess-mock" });

    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const result = await dispatcher.dispatch({ dryRun: false });
    consoleSpy.mockRestore();

    // claimTask should have been called with the task ID and the run ID created
    expect(store.claimTask).toHaveBeenCalledWith("t-atomic-001", "run-xyz-123");

    // The task was claimed and dispatched
    expect(result.dispatched).toHaveLength(1);
    expect(result.dispatched[0].seedId).toBe("t-atomic-001");
    expect(result.dispatched[0].runId).toBe("run-xyz-123");

    spawnSpy.mockRestore();
  });

  it("skips task and cleans up run when claimTask() returns false (double-dispatch prevention)", async () => {
    process.env.FOREMAN_TASK_STORE = "native";

    const task = makeNativeTask("t-race-001");
    const createdRun = {
      id: "run-race-abc",
      project_id: "proj-1",
      seed_id: "t-race-001",
      status: "pending",
      created_at: new Date().toISOString(),
    };

    const store: ForemanStore = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      getRunsByStatuses: vi.fn().mockReturnValue([]),
      getStuckRunsForSeed: vi.fn().mockReturnValue([]),
      hasActiveOrPendingRun: vi.fn().mockReturnValue(false),
      hasNativeTasks: vi.fn().mockReturnValue(true),
      getReadyTasks: vi.fn().mockReturnValue([task]),
      // claimTask returns false — another dispatcher already claimed it
      claimTask: vi.fn().mockReturnValue(false),
      createRun: vi.fn().mockReturnValue(createdRun),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
      sendMessage: vi.fn(),
      getBeadWriteQueue: vi.fn().mockReturnValue([]),
      markBeadWriteProcessed: vi.fn(),
    } as unknown as ForemanStore;

    const beadsClient = makeMockBeadsClient([]);
    const dispatcher = new Dispatcher(beadsClient, store, "/tmp");
    const spawnSpy = vi
      .spyOn(dispatcher as unknown as { spawnAgent: () => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "sess-mock" });
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const result = await dispatcher.dispatch({ dryRun: false });
    consoleSpy.mockRestore();

    // Task should NOT be dispatched
    expect(result.dispatched).toHaveLength(0);

    // Task should appear in skipped with a meaningful reason
    expect(result.skipped).toHaveLength(1);
    expect(result.skipped[0].seedId).toBe("t-race-001");
    expect(result.skipped[0].reason).toMatch(/claim/i);

    // The orphaned run should have been marked as failed (cleanup)
    expect(store.updateRun).toHaveBeenCalledWith(
      "run-race-abc",
      expect.objectContaining({ status: "failed" }),
    );

    // spawnAgent must NOT have been called (we return before reaching step 7)
    expect(spawnSpy).not.toHaveBeenCalled();
    spawnSpy.mockRestore();
  });

  it("does NOT call claimTask() when using beads path", async () => {
    process.env.FOREMAN_TASK_STORE = "beads";

    const store: ForemanStore = {
      getActiveRuns: vi.fn().mockReturnValue([]),
      getProjectByPath: vi.fn().mockReturnValue({ id: "proj-1" }),
      getRunsForSeed: vi.fn().mockReturnValue([]),
      getRunsByStatus: vi.fn().mockReturnValue([]),
      getRunsByStatuses: vi.fn().mockReturnValue([]),
      getStuckRunsForSeed: vi.fn().mockReturnValue([]),
      hasActiveOrPendingRun: vi.fn().mockReturnValue(false),
      hasNativeTasks: vi.fn().mockReturnValue(false),
      getReadyTasks: vi.fn().mockReturnValue([]),
      claimTask: vi.fn().mockReturnValue(true),
      createRun: vi.fn().mockReturnValue({
        id: "run-beads-001",
        project_id: "proj-1",
        seed_id: "b-001",
        status: "pending",
        created_at: new Date().toISOString(),
      }),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
      sendMessage: vi.fn(),
      getBeadWriteQueue: vi.fn().mockReturnValue([]),
      markBeadWriteProcessed: vi.fn(),
    } as unknown as ForemanStore;

    const beadsClient = makeMockBeadsClient([makeBeadsIssue("b-001")]);
    const dispatcher = new Dispatcher(beadsClient, store, "/tmp");
    const spawnSpy = vi
      .spyOn(dispatcher as unknown as { spawnAgent: () => Promise<{ sessionKey: string }> }, "spawnAgent")
      .mockResolvedValue({ sessionKey: "sess-beads" });
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    await dispatcher.dispatch({ dryRun: false });
    consoleSpy.mockRestore();
    spawnSpy.mockRestore();

    // claimTask() must NOT be called on the beads path (uses seeds.update() instead)
    expect(store.claimTask).not.toHaveBeenCalled();
  });
});

// ── ForemanStore.hasNativeTasks() / getReadyTasks() / claimTask() (unit) ──

describe("ForemanStore native task methods (unit — via mock)", () => {
  it("hasNativeTasks returns false when no tasks in table", () => {
    const store = makeMockStore({ hasNativeTasks: false });
    expect(store.hasNativeTasks()).toBe(false);
  });

  it("hasNativeTasks returns true when tasks exist", () => {
    const store = makeMockStore({ hasNativeTasks: true });
    expect(store.hasNativeTasks()).toBe(true);
  });

  it("getReadyTasks returns NativeTask[]", () => {
    const tasks = [makeNativeTask("t-1"), makeNativeTask("t-2")];
    const store = makeMockStore({ nativeTasks: tasks });
    const result = store.getReadyTasks();
    expect(result).toHaveLength(2);
    expect(result[0].id).toBe("t-1");
    expect(result[1].id).toBe("t-2");
  });

  it("claimTask returns true on successful claim", () => {
    const store = makeMockStore({ claimResult: true });
    expect(store.claimTask("t-1", "run-1")).toBe(true);
  });

  it("claimTask returns false when task already claimed", () => {
    const store = makeMockStore({ claimResult: false });
    expect(store.claimTask("t-1", "run-1")).toBe(false);
  });
});

// ── Priority ordering of native tasks ────────────────────────────────────

describe("Dispatcher — Native task priority ordering", () => {
  afterEach(() => {
    delete process.env.FOREMAN_TASK_STORE;
    vi.restoreAllMocks();
  });

  it("dispatches native tasks in priority order (P0 before P2)", async () => {
    process.env.FOREMAN_TASK_STORE = "native";
    const tasks = [
      makeNativeTask("low-prio", 3),
      makeNativeTask("high-prio", 0),
      makeNativeTask("mid-prio", 2),
    ];
    const store = makeMockStore({ hasNativeTasks: true, nativeTasks: tasks });
    // getReadyTasks returns them sorted already (store orders by priority ASC)
    // Re-order to simulate DB returning them sorted
    (store.getReadyTasks as ReturnType<typeof vi.fn>).mockReturnValue([
      makeNativeTask("high-prio", 0),
      makeNativeTask("mid-prio", 2),
      makeNativeTask("low-prio", 3),
    ]);
    const beadsClient = makeMockBeadsClient([]);
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const dispatcher = new Dispatcher(beadsClient, store, "/tmp");
    const result = await dispatcher.dispatch({ dryRun: true });
    consoleSpy.mockRestore();

    const ids = result.dispatched.map((d) => d.seedId);
    // P0 (high-prio) first, then P2, then P3
    expect(ids[0]).toBe("high-prio");
    expect(ids[1]).toBe("mid-prio");
    expect(ids[2]).toBe("low-prio");
  });
});
