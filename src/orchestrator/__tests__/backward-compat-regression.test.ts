/**
 * Backward Compatibility Regression Tests — TRD-006 / REQ-020
 *
 * Verifies that the coexistence of native task store (SQLite `tasks` table)
 * and beads_rust (br CLI) maintains backward compatibility with existing
 * foreman workflows.
 *
 * Tests covered:
 *   1. foreman status (fetchStatusCounts) works when tasks table is absent
 *   2. Dispatcher falls back to beads when hasNativeTasks() returns false (empty table)
 *   3. foreman init on existing DB preserves all tables and runs migrations idempotently
 *   4. Coexistence: empty native store + beads data present → uses beads
 *   5. Coexistence: non-empty native store → uses native
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { randomUUID } from "node:crypto";

import { ForemanStore } from "../../lib/store.js";
import {
  NativeTaskStore,
} from "../../lib/task-store.js";
import {
  Dispatcher,
  resolveTaskStoreMode,
  type TaskStoreMode,
} from "../dispatcher.js";
import type { ITaskClient, Issue } from "../../lib/task-client.js";
import type { NativeTask } from "../../lib/store.js";

// ── Fixtures ─────────────────────────────────────────────────────────────

function setupStore(): { store: ForemanStore; tmpDir: string } {
  const tmpDir = mkdtempSync(join(tmpdir(), "foreman-backward-compat-test-"));
  const dbPath = join(tmpDir, "test.db");
  const store = new ForemanStore(dbPath);
  return { store, tmpDir };
}

function teardownStore(ctx: { store: ForemanStore; tmpDir: string }): void {
  ctx.store.close();
  rmSync(ctx.tmpDir, { recursive: true, force: true });
}

// ── Mock helpers ─────────────────────────────────────────────────────────

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

function makeMockBeadsClient(issues: Issue[] = []): ITaskClient {
  return {
    ready: vi.fn().mockResolvedValue(issues),
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
    claimTask: vi.fn().mockReturnValue(opts.claimResult ?? true),
    createRun: vi.fn().mockReturnValue({ id: "run-001", project_id: "proj-1", seed_id: "" }),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    sendMessage: vi.fn(),
    getBeadWriteQueue: vi.fn().mockReturnValue([]),
    markBeadWriteProcessed: vi.fn(),
  } as unknown as ForemanStore;
}

// ── VCS / filesystem mocks (same as dispatcher-native.test.ts) ─────────────

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

// ── Test Suite ───────────────────────────────────────────────────────────

// ── Test 1: foreman status works when tasks table is absent ───────────────

describe("fetchStatusCounts — backward compat when tasks table absent", () => {
  /**
   * Simulates a legacy database that has no `tasks` table yet.
   * The tasks table is created via CREATE TABLE IF NOT EXISTS in the ForemanStore
   * constructor, so a fresh store always has it. To simulate a pre-existing DB
   * without the tasks table, we create the store, then DROP the table.
   *
   * NOTE: getReadyTasks() does NOT handle missing table gracefully — it will throw.
   * This is expected because the dispatcher only calls getReadyTasks() after
   * hasNativeTasks() returns true (table exists and has rows). This test
   * verifies hasNativeTasks() correctly detects the missing table.
   */
  it("store.hasNativeTasks() returns false after dropping tasks table (legacy DB)", () => {
    const { store, tmpDir } = setupStore();
    try {
      // The store constructor creates the tasks table via CREATE TABLE IF NOT EXISTS.
      // Drop it to simulate a legacy pre-TRD-006 database.
      store.getDb().exec("DROP TABLE IF EXISTS tasks");
      store.getDb().exec("DROP TABLE IF EXISTS task_dependencies");

      // hasNativeTasks() should return false without crashing
      expect(store.hasNativeTasks()).toBe(false);
    } finally {
      teardownStore({ store, tmpDir });
    }
  });

  it("NativeTaskStore.hasNativeTasks() returns false when table is empty", () => {
    const { store, tmpDir } = setupStore();
    try {
      const taskStore = new NativeTaskStore(store.getDb());
      expect(taskStore.hasNativeTasks()).toBe(false);
    } finally {
      teardownStore({ store, tmpDir });
    }
  });

  it("NativeTaskStore.hasNativeTasks() returns true after creating a task", () => {
    const { store, tmpDir } = setupStore();
    try {
      const taskStore = new NativeTaskStore(store.getDb());
      expect(taskStore.hasNativeTasks()).toBe(false);
      taskStore.create({ title: "New Task" });
      expect(taskStore.hasNativeTasks()).toBe(true);
    } finally {
      teardownStore({ store, tmpDir });
    }
  });
});

// ── Test 2: Dispatcher falls back to beads when hasNativeTasks() returns false ─

describe("Dispatcher fallback to beads when native tasks absent", () => {
  afterEach(() => {
    delete process.env.FOREMAN_TASK_STORE;
    vi.restoreAllMocks();
  });

  it("dispatcher uses beads path when hasNativeTasks() returns false", async () => {
    const store = makeMockStore({ hasNativeTasks: false, nativeTasks: [] });
    const beadsClient = makeMockBeadsClient([makeBeadsIssue("b-001"), makeBeadsIssue("b-002")]);

    const dispatcher = new Dispatcher(beadsClient, store, "/tmp");
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const result = await dispatcher.dispatch({ dryRun: true });
    consoleSpy.mockRestore();

    // Beads tasks dispatched
    expect(result.dispatched.map((d) => d.seedId)).toContain("b-001");
    expect(result.dispatched.map((d) => d.seedId)).toContain("b-002");

    // Beads client queried; native store NOT queried
    expect(beadsClient.ready).toHaveBeenCalled();
    expect(store.getReadyTasks).not.toHaveBeenCalled();
  });

  it("dispatcher uses native path when hasNativeTasks() returns true", async () => {
    const nativeTasks = [makeNativeTask("n-001")];
    const store = makeMockStore({ hasNativeTasks: true, nativeTasks });
    const beadsClient = makeMockBeadsClient([makeBeadsIssue("b-001")]);

    const dispatcher = new Dispatcher(beadsClient, store, "/tmp");
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const result = await dispatcher.dispatch({ dryRun: true });
    consoleSpy.mockRestore();

    // Native tasks dispatched, not beads
    expect(result.dispatched.map((d) => d.seedId)).toContain("n-001");
    expect(result.dispatched.map((d) => d.seedId)).not.toContain("b-001");

    // Native store queried; beads NOT queried
    expect(store.getReadyTasks).toHaveBeenCalled();
    expect(beadsClient.ready).not.toHaveBeenCalled();
  });
});

// ── Test 3: foreman init on existing DB preserves data and migrations are idempotent ─

describe("ForemanStore migrations are idempotent (backward compat)", () => {
  it("opening existing DB preserves all tables", () => {
    const { store: store1, tmpDir } = setupStore();
    try {
      // Register a project and create a run to populate tables
      const project = store1.registerProject("test-project", "/tmp/test-project");
      const run = store1.createRun(project.id, "seed-001", "runner", undefined, {
        baseBranch: "main",
      });

      // Record an event
      store1.logEvent(project.id, "dispatch", { seedId: "seed-001" }, run.id);

      // Record a cost
      store1.recordCost(run.id, 1000, 500, 0, 0.05);

      // Verify tables exist and have data
      expect(store1.getProject(project.id)?.id).toBe(project.id);
      expect(store1.getRun(run.id)?.id).toBe(run.id);
      expect(store1.getRunsForSeed("seed-001")).toHaveLength(1);
      expect(store1.getEvents(project.id).length).toBeGreaterThan(0);
      expect(store1.getCosts(project.id).length).toBeGreaterThan(0);

      // Re-open the same DB (simulates running foreman init again)
      store1.close();

      const dbPath = join(tmpDir, "test.db");
      const store2 = new ForemanStore(dbPath);

      try {
        // All data should be preserved
        expect(store2.getProject(project.id)?.id).toBe(project.id);
        expect(store2.getRun(run.id)?.id).toBe(run.id);
        expect(store2.getRunsForSeed("seed-001")).toHaveLength(1);
        expect(store2.getEvents(project.id).length).toBeGreaterThan(0);
        expect(store2.getCosts(project.id).length).toBeGreaterThan(0);
      } finally {
        store2.close();
      }
    } finally {
      // store1 already closed above
      rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("tasks table is created on re-open even if dropped (CREATE TABLE IF NOT EXISTS)", () => {
    const { store: store1, tmpDir } = setupStore();
    try {
      // Create a native task
      const taskStore = new NativeTaskStore(store1.getDb());
      const task = taskStore.create({ title: "Persistence Test Task" });
      expect(taskStore.hasNativeTasks()).toBe(true);

      // Drop the tasks table to simulate legacy DB without tasks
      store1.getDb().exec("DROP TABLE IF EXISTS tasks");
      store1.getDb().exec("DROP TABLE IF EXISTS task_dependencies");
      expect(store1.hasNativeTasks()).toBe(false);

      store1.close();

      // Re-open the DB — schema migrations should re-create tasks table
      const dbPath = join(tmpDir, "test.db");
      const store2 = new ForemanStore(dbPath);

      try {
        // tasks table should exist again (re-created by constructor)
        expect(store2.hasNativeTasks()).toBe(false); // but empty

        // Can create a new task
        const taskStore2 = new NativeTaskStore(store2.getDb());
        const newTask = taskStore2.create({ title: "New Task After Re-open" });
        expect(newTask.id).toBeTruthy();
        expect(store2.hasNativeTasks()).toBe(true);
      } finally {
        store2.close();
      }
    } finally {
      rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  it("multiple sequential opens are idempotent and do not corrupt data", () => {
    const { tmpDir } = setupStore();
    try {
      const dbPath = join(tmpDir, "multi-open.db");

      // Open 1: register project
      const store1 = new ForemanStore(dbPath);
      const project = store1.registerProject("multi-open-proj", "/tmp/multi-open");
      const run1 = store1.createRun(project.id, "seed-1", "runner");
      store1.close();

      // Open 2: add more data
      const store2 = new ForemanStore(dbPath);
      const run2 = store2.createRun(project.id, "seed-2", "runner");
      store2.close();

      // Open 3: verify all data intact
      const store3 = new ForemanStore(dbPath);
      expect(store3.getProject(project.id)?.id).toBe(project.id);
      expect(store3.getRunsForSeed("seed-1")).toHaveLength(1);
      expect(store3.getRunsForSeed("seed-2")).toHaveLength(1);
      expect(store3.getActiveRuns()).toHaveLength(2);
      store3.close();
    } finally {
      rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});

// ── Test 4: Coexistence — empty native store + beads → uses beads ─────────

describe("Coexistence: empty native store uses beads", () => {
  afterEach(() => {
    delete process.env.FOREMAN_TASK_STORE;
    vi.restoreAllMocks();
  });

  it("empty native store + beads data present → uses beads", async () => {
    // hasNativeTasks returns false (empty), but beads has data
    const store = makeMockStore({ hasNativeTasks: false, nativeTasks: [] });
    const beadsClient = makeMockBeadsClient([
      makeBeadsIssue("beads-task-1"),
      makeBeadsIssue("beads-task-2"),
    ]);

    const dispatcher = new Dispatcher(beadsClient, store, "/tmp");
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const result = await dispatcher.dispatch({ dryRun: true });
    consoleSpy.mockRestore();

    // Beads tasks used
    const dispatchedIds = result.dispatched.map((d) => d.seedId);
    expect(dispatchedIds).toContain("beads-task-1");
    expect(dispatchedIds).toContain("beads-task-2");
    expect(dispatchedIds).not.toContain("n-");

    // Beads path taken
    expect(beadsClient.ready).toHaveBeenCalled();
    expect(store.getReadyTasks).not.toHaveBeenCalled();
  });
});

// ── Test 5: Coexistence — non-empty native store → uses native ─────────────

describe("Coexistence: non-empty native store uses native", () => {
  afterEach(() => {
    delete process.env.FOREMAN_TASK_STORE;
    vi.restoreAllMocks();
  });

  it("non-empty native store → uses native even when beads also has data", async () => {
    // hasNativeTasks returns true (has tasks), but beads also has data
    const nativeTasks = [makeNativeTask("native-task-1"), makeNativeTask("native-task-2")];
    const store = makeMockStore({ hasNativeTasks: true, nativeTasks });
    const beadsClient = makeMockBeadsClient([
      makeBeadsIssue("beads-task-1"),
    ]);

    const dispatcher = new Dispatcher(beadsClient, store, "/tmp");
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const result = await dispatcher.dispatch({ dryRun: true });
    consoleSpy.mockRestore();

    // Native tasks used
    const dispatchedIds = result.dispatched.map((d) => d.seedId);
    expect(dispatchedIds).toContain("native-task-1");
    expect(dispatchedIds).toContain("native-task-2");
    expect(dispatchedIds).not.toContain("beads-task-1");

    // Native path taken
    expect(store.getReadyTasks).toHaveBeenCalled();
    expect(beadsClient.ready).not.toHaveBeenCalled();
  });
});

// ── Test 6: resolveTaskStoreMode env var override ─────────────────────────

describe("resolveTaskStoreMode — FOREMAN_TASK_STORE env var (backward compat)", () => {
  afterEach(() => {
    delete process.env.FOREMAN_TASK_STORE;
  });

  it("returns 'auto' when FOREMAN_TASK_STORE is not set", () => {
    delete process.env.FOREMAN_TASK_STORE;
    expect(resolveTaskStoreMode()).toBe("auto");
  });

  it("FOREMAN_TASK_STORE=native forces native store", () => {
    process.env.FOREMAN_TASK_STORE = "native";
    expect(resolveTaskStoreMode()).toBe("native");
  });

  it("FOREMAN_TASK_STORE=beads forces beads store", () => {
    process.env.FOREMAN_TASK_STORE = "beads";
    expect(resolveTaskStoreMode()).toBe("beads");
  });

  it("FOREMAN_TASK_STORE=auto returns auto mode", () => {
    process.env.FOREMAN_TASK_STORE = "auto";
    expect(resolveTaskStoreMode()).toBe("auto");
  });

  it("invalid FOREMAN_TASK_STORE value falls back to 'auto'", () => {
    process.env.FOREMAN_TASK_STORE = "invalid-value";
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const mode = resolveTaskStoreMode();
    consoleSpy.mockRestore();
    expect(mode).toBe("auto");
  });

  it("empty string FOREMAN_TASK_STORE falls back to 'auto'", () => {
    process.env.FOREMAN_TASK_STORE = "";
    expect(resolveTaskStoreMode()).toBe("auto");
  });
});

// ── Test 7: Real ForemanStore hasNativeTasks() behavior ───────────────────

describe("ForemanStore.hasNativeTasks() — real DB behavior", () => {
  it("hasNativeTasks returns false for fresh store (no tasks)", () => {
    const { store, tmpDir } = setupStore();
    try {
      expect(store.hasNativeTasks()).toBe(false);
    } finally {
      teardownStore({ store, tmpDir });
    }
  });

  it("hasNativeTasks returns true after NativeTaskStore creates a task", () => {
    const { store, tmpDir } = setupStore();
    try {
      const taskStore = new NativeTaskStore(store.getDb());
      expect(store.hasNativeTasks()).toBe(false);
      taskStore.create({ title: "Real Task" });
      expect(store.hasNativeTasks()).toBe(true);
    } finally {
      teardownStore({ store, tmpDir });
    }
  });

  it("hasNativeTasks returns true after all native tasks are closed (task still exists)", () => {
    const { store, tmpDir } = setupStore();
    try {
      const taskStore = new NativeTaskStore(store.getDb());
      const task = taskStore.create({ title: "Task to Close" });
      taskStore.approve(task.id);
      taskStore.close(task.id);

      // After closing, hasNativeTasks should still return true
      // because the task still exists in the table (just with status='merged')
      expect(store.hasNativeTasks()).toBe(true);

      // But ready tasks should be empty
      expect(store.getReadyTasks()).toEqual([]);
    } finally {
      teardownStore({ store, tmpDir });
    }
  });

  it("claimTask returns false when task does not exist", () => {
    const { store, tmpDir } = setupStore();
    try {
      // Note: Without a valid run_id, the FK constraint would fail.
      // But claimTask returns false early if task doesn't exist (before FK check)
      expect(store.claimTask("non-existent-id", "run-001")).toBe(false);
    } finally {
      teardownStore({ store, tmpDir });
    }
  });

  it("claimTask returns true when task exists and is ready (with valid run FK)", () => {
    const { store, tmpDir } = setupStore();
    try {
      // Create project and run for FK compliance
      const project = store.registerProject("test-proj", "/tmp/test-proj");
      const run = store.createRun(project.id, "seed-001", "runner");

      const taskStore = new NativeTaskStore(store.getDb());
      const task = taskStore.create({ title: "Claimable Task" });
      taskStore.approve(task.id);

      expect(store.claimTask(task.id, run.id)).toBe(true);

      // Task is no longer in ready list
      expect(store.getReadyTasks()).toEqual([]);
    } finally {
      teardownStore({ store, tmpDir });
    }
  });

  it("claimTask returns false when task already claimed by different run", () => {
    const { store, tmpDir } = setupStore();
    try {
      // Create project and runs for FK compliance
      const project = store.registerProject("test-proj", "/tmp/test-proj");
      const run1 = store.createRun(project.id, "seed-001", "runner");
      const run2 = store.createRun(project.id, "seed-002", "runner");

      const taskStore = new NativeTaskStore(store.getDb());
      const task = taskStore.create({ title: "Contested Task" });
      taskStore.approve(task.id);

      // First claim succeeds
      expect(store.claimTask(task.id, run1.id)).toBe(true);

      // Second claim by different run fails
      expect(store.claimTask(task.id, run2.id)).toBe(false);
    } finally {
      teardownStore({ store, tmpDir });
    }
  });

  it("claimTask is NOT idempotent for same run (status check blocks re-claim)", () => {
    const { store, tmpDir } = setupStore();
    try {
      // Create project and run for FK compliance
      const project = store.registerProject("test-proj", "/tmp/test-proj");
      const run = store.createRun(project.id, "seed-001", "runner");

      const taskStore = new NativeTaskStore(store.getDb());
      const task = taskStore.create({ title: "Idempotent Claim" });
      taskStore.approve(task.id);

      // First claim succeeds
      expect(store.claimTask(task.id, run.id)).toBe(true);

      // Second claim by same run — returns false because status is no longer 'ready'
      // Note: ForemanStore.claimTask() is NOT idempotent due to the WHERE status='ready' clause
      // This differs from NativeTaskStore.claim() which IS idempotent for same run.
      expect(store.claimTask(task.id, run.id)).toBe(false);
    } finally {
      teardownStore({ store, tmpDir });
    }
  });
});
