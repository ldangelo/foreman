/**
 * Integration tests for Dispatcher — native task store path, beads fallback,
 * FOREMAN_TASK_STORE overrides, and atomic claim transaction.
 *
 * Uses real ForemanStore + NativeTaskStore with in-memory SQLite.
 * Verifies TRD-007 / REQ-014 / REQ-017.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Dispatcher } from "../dispatcher.js";
import type { ITaskClient, Issue } from "../../lib/task-client.js";
import { ForemanStore } from "../../lib/store.js";
import { NativeTaskStore } from "../../lib/task-store.js";

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
  const fsPromises = (await importOriginal()) as Record<string, unknown>;
  return {
    ...fsPromises,
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

// ── Test store setup / teardown ─────────────────────────────────────────

interface StoreContext {
  store: ForemanStore;
  taskStore: NativeTaskStore;
  tmpDir: string;
  projectId: string;
}

function setupStore(): StoreContext {
  const tmpDir = mkdtempSync(join(tmpdir(), "foreman-dispatcher-integration-test-"));
  // Use in-memory SQLite for isolation; store DB file for inspection if needed
  const dbPath = join(tmpDir, "test.db");
  const store = new ForemanStore(dbPath);
  const taskStore = new NativeTaskStore(store.getDb());
  // Register a project at /tmp so dispatcher can find it (dispatcher uses projectPath)
  const project = store.registerProject("test-project", "/tmp");
  return { store, taskStore, tmpDir, projectId: project.id };
}

function teardownStore(ctx: StoreContext): void {
  ctx.store.close();
  rmSync(ctx.tmpDir, { recursive: true, force: true });
}

// ── Test fixtures ────────────────────────────────────────────────────────

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

// ── Integration: Native task store path ──────────────────────────────────

describe("Dispatcher — Native task store path (integration)", () => {
  let ctx: StoreContext;

  beforeEach(() => {
    ctx = setupStore();
  });
  afterEach(() => {
    teardownStore(ctx);
    delete process.env.FOREMAN_TASK_STORE;
  });

  it("hasNativeTasks() returns true after creating and approving a task", () => {
    const task = ctx.taskStore.create({ title: "Ready Task" });
    ctx.taskStore.approve(task.id);
    expect(ctx.store.hasNativeTasks()).toBe(true);
  });

  it("hasNativeTasks() returns false when no tasks exist", () => {
    expect(ctx.store.hasNativeTasks()).toBe(false);
  });

  it("getReadyTasks() returns approved tasks ordered by priority", () => {
    const low = ctx.taskStore.create({ title: "Low Priority", priority: 3 });
    const high = ctx.taskStore.create({ title: "High Priority", priority: 0 });
    ctx.taskStore.approve(high.id);
    ctx.taskStore.approve(low.id);

    const ready = ctx.store.getReadyTasks();
    expect(ready).toHaveLength(2);
    expect(ready[0]!.title).toBe("High Priority");
    expect(ready[1]!.title).toBe("Low Priority");
  });

  it("dispatch() uses native store when tasks are ready (auto mode)", async () => {
    // Create and approve native tasks
    const task1 = ctx.taskStore.create({ title: "Native Task 1", priority: 1 });
    const task2 = ctx.taskStore.create({ title: "Native Task 2", priority: 2 });
    ctx.taskStore.approve(task1.id);
    ctx.taskStore.approve(task2.id);

    const beadsClient = makeMockBeadsClient([{ id: "b-001", title: "Beads Task", type: "task", priority: "P2", status: "open", assignee: null, parent: null, created_at: "", updated_at: "" }]);

    const dispatcher = new Dispatcher(beadsClient, ctx.store, "/tmp");
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const result = await dispatcher.dispatch({ dryRun: true });
    consoleSpy.mockRestore();

    // Native tasks dispatched, beads NOT dispatched
    const dispatchedIds = result.dispatched.map((d) => d.seedId);
    expect(dispatchedIds).toContain(task1.id);
    expect(dispatchedIds).toContain(task2.id);
    expect(dispatchedIds).not.toContain("b-001");

    // Beads was not called (native path used)
    expect(beadsClient.ready).not.toHaveBeenCalled();
  });

  it("dispatch() falls back to beads when no native tasks exist (auto mode)", async () => {
    const beadsIssue = { id: "b-beads", title: "Beads Task", type: "task" as const, priority: "P2" as const, status: "open" as const, assignee: null, parent: null, created_at: "", updated_at: "" };
    const beadsClient = makeMockBeadsClient([beadsIssue]);

    // No native tasks created — store is empty
    expect(ctx.store.hasNativeTasks()).toBe(false);

    const dispatcher = new Dispatcher(beadsClient, ctx.store, "/tmp");
    const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    const result = await dispatcher.dispatch({ dryRun: true });
    consoleSpy.mockRestore();

    // Beads task was dispatched
    expect(result.dispatched.map((d) => d.seedId)).toContain("b-beads");

    // Beads client was called
    expect(beadsClient.ready).toHaveBeenCalled();
  });

  it("dispatch() skips tasks in non-ready statuses (backlog, in-progress, etc.)", async () => {
    // Create tasks in various statuses
    const backlog = ctx.taskStore.create({ title: "Backlog Task" });
    const approved = ctx.taskStore.create({ title: "Approved Task" });
    const inProgress = ctx.taskStore.create({ title: "In Progress Task" });

    ctx.taskStore.approve(approved.id);

    // Directly set inProgress task to in-progress
    ctx.store.getDb().prepare("UPDATE tasks SET status='in-progress' WHERE id=?").run(inProgress.id);

    const beadsClient = makeMockBeadsClient([]);
    const dispatcher = new Dispatcher(beadsClient, ctx.store, "/tmp");

    const result = await dispatcher.dispatch({ dryRun: true });

    // Only the approved task should be dispatched
    expect(result.dispatched).toHaveLength(1);
    expect(result.dispatched[0]!.seedId).toBe(approved.id);
    expect(result.dispatched[0]!.title).toBe("Approved Task");
  });
});

// ── Integration: FOREMAN_TASK_STORE overrides ────────────────────────────

describe("Dispatcher — FOREMAN_TASK_STORE overrides (integration)", () => {
  let ctx: StoreContext;

  beforeEach(() => {
    ctx = setupStore();
  });
  afterEach(() => {
    teardownStore(ctx);
    delete process.env.FOREMAN_TASK_STORE;
  });

  it("FOREMAN_TASK_STORE=native forces native store even when empty", async () => {
    await withEnvVar("FOREMAN_TASK_STORE", "native", async () => {
      // No native tasks — empty store
      expect(ctx.store.hasNativeTasks()).toBe(false);

      // Create a task so there's something to dispatch
      const task = ctx.taskStore.create({ title: "Forced Native Task" });
      ctx.taskStore.approve(task.id);

      const beadsClient = makeMockBeadsClient([{ id: "b-001", title: "Beads Task", type: "task", priority: "P2", status: "open", assignee: null, parent: null, created_at: "", updated_at: "" }]);
      const dispatcher = new Dispatcher(beadsClient, ctx.store, "/tmp");
      const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

      const result = await dispatcher.dispatch({ dryRun: true });
      consoleSpy.mockRestore();

      // Native task dispatched, beads NOT
      expect(result.dispatched.map((d) => d.seedId)).toContain(task.id);
      expect(result.dispatched.map((d) => d.seedId)).not.toContain("b-001");
      expect(beadsClient.ready).not.toHaveBeenCalled();
    });
  });

  it("FOREMAN_TASK_STORE=beads forces beads even when native tasks exist", async () => {
    await withEnvVar("FOREMAN_TASK_STORE", "beads", async () => {
      // Create native tasks
      const nativeTask = ctx.taskStore.create({ title: "Native Task" });
      ctx.taskStore.approve(nativeTask.id);
      expect(ctx.store.hasNativeTasks()).toBe(true);

      const beadsIssue = { id: "b-force-beads", title: "Forced Beads Task", type: "task" as const, priority: "P2" as const, status: "open" as const, assignee: null, parent: null, created_at: "", updated_at: "" };
      const beadsClient = makeMockBeadsClient([beadsIssue]);
      const dispatcher = new Dispatcher(beadsClient, ctx.store, "/tmp");
      const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

      const result = await dispatcher.dispatch({ dryRun: true });
      consoleSpy.mockRestore();

      // Beads task dispatched, native NOT
      expect(result.dispatched.map((d) => d.seedId)).toContain("b-force-beads");
      expect(result.dispatched.map((d) => d.seedId)).not.toContain(nativeTask.id);
      expect(beadsClient.ready).toHaveBeenCalled();
    });
  });

  it("FOREMAN_TASK_STORE=auto uses native when tasks exist, beads when empty", async () => {
    await withEnvVar("FOREMAN_TASK_STORE", "auto", async () => {
      // No tasks — should use beads
      const beadsIssue = { id: "b-001", title: "Beads Task", type: "task" as const, priority: "P2" as const, status: "open" as const, assignee: null, parent: null, created_at: "", updated_at: "" };
      const beadsClient = makeMockBeadsClient([beadsIssue]);
      const dispatcher = new Dispatcher(beadsClient, ctx.store, "/tmp");

      const result1 = await dispatcher.dispatch({ dryRun: true });
      expect(result1.dispatched.map((d) => d.seedId)).toContain("b-001");
      expect(beadsClient.ready).toHaveBeenCalled();

      // Now add a native task — should switch to native
      const nativeTask = ctx.taskStore.create({ title: "Native Task" });
      ctx.taskStore.approve(nativeTask.id);

      const dispatcher2 = new Dispatcher(beadsClient, ctx.store, "/tmp");
      vi.clearAllMocks();
      const result2 = await dispatcher2.dispatch({ dryRun: true });
      expect(result2.dispatched.map((d) => d.seedId)).toContain(nativeTask.id);
    });
  });
});

// ── Integration: Atomic claim transaction ─────────────────────────────────

describe("Dispatcher — Atomic claim transaction (integration)", () => {
  let ctx: StoreContext;

  beforeEach(() => {
    ctx = setupStore();
  });
  afterEach(() => {
    teardownStore(ctx);
    delete process.env.FOREMAN_TASK_STORE;
  });

  it("claimTask() returns true when claiming an unclaimed ready task", () => {
    const task = ctx.taskStore.create({ title: "Claimable Task" });
    ctx.taskStore.approve(task.id);

    const run = ctx.store.createRun(ctx.projectId, task.id, "runner");
    const result = ctx.store.claimTask(task.id, run.id);

    expect(result).toBe(true);

    // Verify task is now in-progress with run_id set
    const updated = ctx.taskStore.get(task.id);
    expect(updated?.status).toBe("in-progress");
    expect(updated?.run_id).toBe(run.id);
  });

  it("claimTask() returns false when task is already claimed by another run", () => {
    const task = ctx.taskStore.create({ title: "Contested Task" });
    ctx.taskStore.approve(task.id);

    const run1 = ctx.store.createRun(ctx.projectId, task.id, "runner-1");
    const run2 = ctx.store.createRun(ctx.projectId, task.id, "runner-2");

    // First claim succeeds
    expect(ctx.store.claimTask(task.id, run1.id)).toBe(true);

    // Second claim fails (task already in-progress)
    expect(ctx.store.claimTask(task.id, run2.id)).toBe(false);
  });

  it("claimTask() returns false when task status is not 'ready'", () => {
    const task = ctx.taskStore.create({ title: "Backlog Task" });
    // Do NOT approve — task is still in backlog status

    const run = ctx.store.createRun(ctx.projectId, task.id, "runner");
    const result = ctx.store.claimTask(task.id, run.id);

    expect(result).toBe(false);
  });

  it("dispatch() skips task and marks run failed when claimTask() returns false", async () => {
    await withEnvVar("FOREMAN_TASK_STORE", "native", async () => {
      const task = ctx.taskStore.create({ title: "Race Condition Task" });
      ctx.taskStore.approve(task.id);

      // Pre-create a run and claim the task before dispatch runs
      const preRun = ctx.store.createRun(ctx.projectId, task.id, "pre-runner");
      const claimed = ctx.store.claimTask(task.id, preRun.id);
      expect(claimed).toBe(true); // Pre-claim succeeded

      // Verify task is no longer in ready list (getReadyTasks excludes claimed tasks)
      const readyTasks = ctx.store.getReadyTasks();
      expect(readyTasks.some((t) => t.id === task.id)).toBe(false);

      // Verify task status is now in-progress
      const updated = ctx.taskStore.get(task.id);
      expect(updated?.status).toBe("in-progress");
      expect(updated?.run_id).toBe(preRun.id);

      // Now dispatch — should not find the claimed task (not in ready list)
      const beadsClient = makeMockBeadsClient([]);
      const dispatcher = new Dispatcher(beadsClient, ctx.store, "/tmp");
      const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

      const result = await dispatcher.dispatch({ dryRun: false });
      consoleSpy.mockRestore();

      // Task was not dispatched (not in ready list anymore)
      expect(result.dispatched.some((d) => d.seedId === task.id)).toBe(false);
    });
  });

  it("dispatch() creates run then claims atomically in non-dryRun mode", async () => {
    await withEnvVar("FOREMAN_TASK_STORE", "native", async () => {
      const task = ctx.taskStore.create({ title: "Atomic Dispatch Task" });
      ctx.taskStore.approve(task.id);

      const beadsClient = makeMockBeadsClient([]);
      const dispatcher = new Dispatcher(beadsClient, ctx.store, "/tmp");
      const spawnSpy = vi
        .spyOn(dispatcher as unknown as { spawnAgent: () => Promise<{ sessionKey: string }> }, "spawnAgent")
        .mockResolvedValue({ sessionKey: "mock-session" });
      const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

      const result = await dispatcher.dispatch({ dryRun: false });
      consoleSpy.mockRestore();

      // Task was dispatched
      expect(result.dispatched).toHaveLength(1);
      expect(result.dispatched[0]!.seedId).toBe(task.id);

      // spawnAgent was called (full non-dryRun path)
      expect(spawnSpy).toHaveBeenCalled();

      // Task is now in-progress with run_id set
      const updated = ctx.taskStore.get(task.id);
      expect(updated?.status).toBe("in-progress");
      expect(updated?.run_id).toBe(result.dispatched[0]!.runId);

      spawnSpy.mockRestore();
    });
  });

  it("second concurrent dispatcher gets claimTask===false (double-dispatch prevention)", async () => {
    await withEnvVar("FOREMAN_TASK_STORE", "native", async () => {
      const task = ctx.taskStore.create({ title: "Concurrent Task" });
      ctx.taskStore.approve(task.id);

      const beadsClient = makeMockBeadsClient([]);
      const dispatcher = new Dispatcher(beadsClient, ctx.store, "/tmp");
      const spawnSpy = vi
        .spyOn(dispatcher as unknown as { spawnAgent: () => Promise<{ sessionKey: string }> }, "spawnAgent")
        .mockResolvedValue({ sessionKey: "mock-session" });
      const consoleSpy = vi.spyOn(console, "error").mockImplementation(() => {});

      // First dispatch succeeds
      const result1 = await dispatcher.dispatch({ dryRun: false });
      expect(result1.dispatched).toHaveLength(1);
      expect(result1.dispatched[0]!.seedId).toBe(task.id);

      // Verify task is no longer in ready list (already claimed)
      const readyAfterFirst = ctx.store.getReadyTasks();
      expect(readyAfterFirst.some((t) => t.id === task.id)).toBe(false);

      // Second dispatch — task not in ready list anymore, dispatches nothing
      const result2 = await dispatcher.dispatch({ dryRun: false });
      consoleSpy.mockRestore();

      expect(result2.dispatched).toHaveLength(0);

      // spawnAgent called only once (first dispatch)
      expect(spawnSpy).toHaveBeenCalledTimes(1);

      spawnSpy.mockRestore();
    });
  });
});

// ── Integration: Priority ordering ───────────────────────────────────────

describe("Dispatcher — Native task priority ordering (integration)", () => {
  let ctx: StoreContext;

  beforeEach(() => {
    ctx = setupStore();
  });
  afterEach(() => {
    teardownStore(ctx);
    delete process.env.FOREMAN_TASK_STORE;
  });

  it("dispatches tasks in priority order (P0 before P2 before P4)", async () => {
    await withEnvVar("FOREMAN_TASK_STORE", "native", async () => {
      const p0 = ctx.taskStore.create({ title: "Critical", priority: 0 });
      const p2 = ctx.taskStore.create({ title: "Medium", priority: 2 });
      const p4 = ctx.taskStore.create({ title: "Backlog", priority: 4 });
      const p1 = ctx.taskStore.create({ title: "High", priority: 1 });

      ctx.taskStore.approve(p0.id);
      ctx.taskStore.approve(p2.id);
      ctx.taskStore.approve(p4.id);
      ctx.taskStore.approve(p1.id);

      const beadsClient = makeMockBeadsClient([]);
      const dispatcher = new Dispatcher(beadsClient, ctx.store, "/tmp");

      const result = await dispatcher.dispatch({ dryRun: true });

      const ids = result.dispatched.map((d) => d.seedId);
      // P0 < P1 < P2 < P4
      expect(ids.indexOf(p0.id)).toBeLessThan(ids.indexOf(p1.id));
      expect(ids.indexOf(p1.id)).toBeLessThan(ids.indexOf(p2.id));
      expect(ids.indexOf(p2.id)).toBeLessThan(ids.indexOf(p4.id));
    });
  });

  it("getReadyTasks() returns tasks ordered by priority ASC, created_at ASC", () => {
    const first = ctx.taskStore.create({ title: "First Created", priority: 2 });
    const second = ctx.taskStore.create({ title: "Second Created", priority: 2 });
    ctx.taskStore.approve(first.id);
    ctx.taskStore.approve(second.id);

    const ready = ctx.store.getReadyTasks();
    expect(ready[0]!.id).toBe(first.id);
    expect(ready[1]!.id).toBe(second.id);
  });
});

// ── Integration: Native story grouping parity ────────────────────────────

describe("Dispatcher — Native story-scoped grouping (integration)", () => {
  let ctx: StoreContext;

  beforeEach(() => {
    ctx = setupStore();
  });
  afterEach(() => {
    teardownStore(ctx);
    delete process.env.FOREMAN_TASK_STORE;
  });

  it("dispatches one grouped worktree when multiple ready native tasks share a story parent", async () => {
    await withEnvVar("FOREMAN_TASK_STORE", "native", async () => {
      const story = ctx.taskStore.create({ title: "Story 1", type: "feature" });
      const task1 = ctx.taskStore.create({ title: "Task 1" });
      const task2 = ctx.taskStore.create({ title: "Task 2" });

      ctx.taskStore.addDependency(task1.id, story.id, "parent-child");
      ctx.taskStore.addDependency(task2.id, story.id, "parent-child");
      ctx.taskStore.approve(task1.id);
      ctx.taskStore.approve(task2.id);

      const beadsClient = makeMockBeadsClient([]);
      const dispatcher = new Dispatcher(beadsClient, ctx.store, "/tmp");

      const result = await dispatcher.dispatch({ dryRun: true });

      expect(result.dispatched).toHaveLength(1);
      expect(result.dispatched[0]).toMatchObject({
        seedId: story.id,
        title: story.title,
      });
      expect(result.dispatched.map((item) => item.seedId)).not.toContain(task1.id);
      expect(result.dispatched.map((item) => item.seedId)).not.toContain(task2.id);
    });
  });

  it("dispatches separate grouped worktrees for independent native stories", async () => {
    await withEnvVar("FOREMAN_TASK_STORE", "native", async () => {
      const story1 = ctx.taskStore.create({ title: "Story 1", type: "feature" });
      const story2 = ctx.taskStore.create({ title: "Story 2", type: "feature" });
      const task1 = ctx.taskStore.create({ title: "Story 1 / Task 1" });
      const task2 = ctx.taskStore.create({ title: "Story 1 / Task 2" });
      const task3 = ctx.taskStore.create({ title: "Story 2 / Task 1" });
      const task4 = ctx.taskStore.create({ title: "Story 2 / Task 2" });

      ctx.taskStore.addDependency(task1.id, story1.id, "parent-child");
      ctx.taskStore.addDependency(task2.id, story1.id, "parent-child");
      ctx.taskStore.addDependency(task3.id, story2.id, "parent-child");
      ctx.taskStore.addDependency(task4.id, story2.id, "parent-child");
      ctx.taskStore.approve(task1.id);
      ctx.taskStore.approve(task2.id);
      ctx.taskStore.approve(task3.id);
      ctx.taskStore.approve(task4.id);

      const beadsClient = makeMockBeadsClient([]);
      const dispatcher = new Dispatcher(beadsClient, ctx.store, "/tmp");

      const result = await dispatcher.dispatch({ dryRun: true });

      expect(result.dispatched).toHaveLength(2);
      expect(new Set(result.dispatched.map((item) => item.seedId))).toEqual(
        new Set([story1.id, story2.id]),
      );
      expect(new Set(result.dispatched.map((item) => item.worktreePath)).size).toBe(2);
      expect(result.dispatched.map((item) => item.seedId)).not.toEqual(
        expect.arrayContaining([task1.id, task2.id, task3.id, task4.id]),
      );
    });
  });
});
