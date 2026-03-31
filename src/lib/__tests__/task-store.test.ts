/**
 * Tests for NativeTaskStore — the native SQLite task management back-end.
 *
 * Covers:
 *   - create() — task creation with UUID, defaults, validation
 *   - approve() — backlog → ready transition
 *   - close()   — set status to merged
 *   - addDependency() — with cycle detection
 *   - getDependencies() — outgoing/incoming directions
 *   - hasCyclicDependency() — DFS cycle detection
 *   - removeDependency() — edge removal
 *   - parsePriority() — alias and numeric parsing
 *   - priorityLabel() — numeric → label conversion
 *   - InvalidStatusTransitionError — error shape
 *   - TaskNotFoundError — error shape
 *   - CircularDependencyError — error shape
 *
 * REQ-003: tasks table with CHECK constraint
 * REQ-004: task_dependencies table for dependency graph
 * REQ-005: approval gate
 * REQ-006: task creation
 * REQ-008: task closure
 * REQ-021.3: circular dependency detection
 */

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ForemanStore } from "../store.js";
import {
  NativeTaskStore,
  parsePriority,
  priorityLabel,
  TaskNotFoundError,
  InvalidStatusTransitionError,
  CircularDependencyError,
  type TaskRow,
  type DependencyRow,
} from "../task-store.js";

// ── Test fixtures ─────────────────────────────────────────────────────────────

function setupStore(): { store: ForemanStore; taskStore: NativeTaskStore; tmpDir: string } {
  const tmpDir = mkdtempSync(join(tmpdir(), "foreman-task-store-test-"));
  const dbPath = join(tmpDir, "test.db");
  const store = new ForemanStore(dbPath);
  const taskStore = new NativeTaskStore(store.getDb());
  return { store, taskStore, tmpDir };
}

function teardownStore(ctx: { store: ForemanStore; tmpDir: string }): void {
  ctx.store.close();
  rmSync(ctx.tmpDir, { recursive: true, force: true });
}

// ── parsePriority ──────────────────────────────────────────────────────────────

describe("parsePriority", () => {
  it("parses numeric strings 0-4", () => {
    expect(parsePriority("0")).toBe(0);
    expect(parsePriority("1")).toBe(1);
    expect(parsePriority("2")).toBe(2);
    expect(parsePriority("3")).toBe(3);
    expect(parsePriority("4")).toBe(4);
  });

  it("parses named aliases", () => {
    expect(parsePriority("critical")).toBe(0);
    expect(parsePriority("high")).toBe(1);
    expect(parsePriority("medium")).toBe(2);
    expect(parsePriority("low")).toBe(3);
    expect(parsePriority("backlog")).toBe(4);
  });

  it("throws RangeError for invalid input", () => {
    expect(() => parsePriority("invalid")).toThrow(RangeError);
    expect(() => parsePriority("5")).toThrow(RangeError);
    expect(() => parsePriority("-1")).toThrow(RangeError);
    expect(() => parsePriority("urgent")).toThrow(RangeError);
  });
});

// ── priorityLabel ──────────────────────────────────────────────────────────────

describe("priorityLabel", () => {
  it("returns correct labels for 0-4", () => {
    expect(priorityLabel(0)).toBe("critical");
    expect(priorityLabel(1)).toBe("high");
    expect(priorityLabel(2)).toBe("medium");
    expect(priorityLabel(3)).toBe("low");
    expect(priorityLabel(4)).toBe("backlog");
  });

  it("returns string representation for unknown values", () => {
    expect(priorityLabel(5)).toBe("5");
    expect(priorityLabel(-1)).toBe("-1");
  });
});

// ── Error classes ──────────────────────────────────────────────────────────────

describe("TaskNotFoundError", () => {
  it("has correct name and message", () => {
    const err = new TaskNotFoundError("abc-123");
    expect(err.name).toBe("TaskNotFoundError");
    expect(err.message).toContain("abc-123");
    expect(err.taskId).toBe("abc-123");
    expect(err).toBeInstanceOf(Error);
  });
});

describe("InvalidStatusTransitionError", () => {
  it("has correct name and message", () => {
    const err = new InvalidStatusTransitionError("t1", "backlog", "merged");
    expect(err.name).toBe("InvalidStatusTransitionError");
    expect(err.message).toContain("backlog");
    expect(err.message).toContain("merged");
    expect(err.fromStatus).toBe("backlog");
    expect(err.toStatus).toBe("merged");
    expect(err).toBeInstanceOf(Error);
  });
});

describe("CircularDependencyError", () => {
  it("has correct name and message", () => {
    const err = new CircularDependencyError("a", "b");
    expect(err.name).toBe("CircularDependencyError");
    expect(err.message).toContain("circular");
    expect(err.fromId).toBe("a");
    expect(err.toId).toBe("b");
    expect(err).toBeInstanceOf(Error);
  });
});

// ── NativeTaskStore.create() ──────────────────────────────────────────────────

describe("NativeTaskStore.create()", () => {
  let ctx: ReturnType<typeof setupStore>;

  beforeEach(() => {
    ctx = setupStore();
  });
  afterEach(() => teardownStore(ctx));

  it("creates a task with required title", () => {
    const task = ctx.taskStore.create({ title: "My Task" });
    expect(task.id).toBeTruthy();
    expect(task.id).toMatch(/^[0-9a-f-]{36}$/); // UUID v4
    expect(task.title).toBe("My Task");
    expect(task.status).toBe("backlog");
    expect(task.type).toBe("task"); // default type
    expect(task.priority).toBe(2); // default medium
    expect(task.description).toBeNull();
    expect(task.external_id).toBeNull();
    expect(task.created_at).toBeTruthy();
    expect(task.updated_at).toBeTruthy();
  });

  it("creates a task with custom options", () => {
    const task = ctx.taskStore.create({
      title: "Bug Fix",
      description: "Fix the crash",
      type: "bug",
      priority: 0,
      externalId: "bd-abc123",
    });
    expect(task.title).toBe("Bug Fix");
    expect(task.description).toBe("Fix the crash");
    expect(task.type).toBe("bug");
    expect(task.priority).toBe(0);
    expect(task.external_id).toBe("bd-abc123");
    expect(task.status).toBe("backlog");
  });

  it("creates tasks with unique UUIDs", () => {
    const t1 = ctx.taskStore.create({ title: "T1" });
    const t2 = ctx.taskStore.create({ title: "T2" });
    expect(t1.id).not.toBe(t2.id);
  });

  it("new tasks are visible in list()", () => {
    ctx.taskStore.create({ title: "Visible Task" });
    const tasks = ctx.taskStore.list();
    expect(tasks.length).toBeGreaterThan(0);
    expect(tasks.some((t) => t.title === "Visible Task")).toBe(true);
  });

  it("new tasks are not visible to dispatcher (status=backlog, not ready)", () => {
    ctx.taskStore.create({ title: "Backlog Task" });
    const readyTasks = ctx.taskStore.list({ status: "ready" });
    expect(readyTasks.every((t) => t.title !== "Backlog Task")).toBe(true);
  });
});

// ── NativeTaskStore.get() ─────────────────────────────────────────────────────

describe("NativeTaskStore.get()", () => {
  let ctx: ReturnType<typeof setupStore>;

  beforeEach(() => {
    ctx = setupStore();
  });
  afterEach(() => teardownStore(ctx));

  it("returns TaskRow for existing task", () => {
    const created = ctx.taskStore.create({ title: "Get Test" });
    const fetched = ctx.taskStore.get(created.id);
    expect(fetched).toBeDefined();
    expect(fetched?.id).toBe(created.id);
    expect(fetched?.title).toBe("Get Test");
  });

  it("returns null for non-existent task", () => {
    const result = ctx.taskStore.get("00000000-0000-0000-0000-000000000000");
    expect(result).toBeNull();
  });
});

// ── NativeTaskStore.approve() ─────────────────────────────────────────────────

describe("NativeTaskStore.approve()", () => {
  let ctx: ReturnType<typeof setupStore>;

  beforeEach(() => {
    ctx = setupStore();
  });
  afterEach(() => teardownStore(ctx));

  it("transitions backlog task to ready", () => {
    const task = ctx.taskStore.create({ title: "Approve Me" });
    ctx.taskStore.approve(task.id);
    const updated = ctx.taskStore.get(task.id);
    expect(updated?.status).toBe("ready");
    expect(updated?.approved_at).toBeTruthy();
  });

  it("approved task is visible to dispatcher", () => {
    const task = ctx.taskStore.create({ title: "Ready Task" });
    ctx.taskStore.approve(task.id);
    const readyTasks = ctx.taskStore.list({ status: "ready" });
    expect(readyTasks.some((t) => t.id === task.id)).toBe(true);
  });

  it("throws TaskNotFoundError for unknown ID", () => {
    expect(() =>
      ctx.taskStore.approve("00000000-0000-0000-0000-000000000000"),
    ).toThrow(TaskNotFoundError);
  });

  it("throws for non-backlog tasks", () => {
    const task = ctx.taskStore.create({ title: "Already Ready" });
    ctx.taskStore.approve(task.id);
    // Try to approve again
    expect(() => ctx.taskStore.approve(task.id)).toThrow();
  });

  it("sets approved_at timestamp on approval", () => {
    const before = new Date().toISOString();
    const task = ctx.taskStore.create({ title: "Timestamp Test" });
    ctx.taskStore.approve(task.id);
    const after = new Date().toISOString();
    const updated = ctx.taskStore.get(task.id);
    expect(updated?.approved_at).toBeTruthy();
    expect(updated?.approved_at! >= before).toBe(true);
    expect(updated?.approved_at! <= after).toBe(true);
  });
});

// ── NativeTaskStore.close() ───────────────────────────────────────────────────

describe("NativeTaskStore.close()", () => {
  let ctx: ReturnType<typeof setupStore>;

  beforeEach(() => {
    ctx = setupStore();
  });
  afterEach(() => teardownStore(ctx));

  it("sets task status to merged", () => {
    const task = ctx.taskStore.create({ title: "Close Me" });
    ctx.taskStore.close(task.id);
    const updated = ctx.taskStore.get(task.id);
    expect(updated?.status).toBe("merged");
    expect(updated?.closed_at).toBeTruthy();
  });

  it("closed task is no longer visible in ready list", () => {
    const task = ctx.taskStore.create({ title: "Close Then Gone" });
    ctx.taskStore.approve(task.id);
    ctx.taskStore.close(task.id);
    const readyTasks = ctx.taskStore.list({ status: "ready" });
    expect(readyTasks.every((t) => t.id !== task.id)).toBe(true);
  });

  it("throws TaskNotFoundError for unknown ID", () => {
    expect(() =>
      ctx.taskStore.close("00000000-0000-0000-0000-000000000000"),
    ).toThrow(TaskNotFoundError);
  });

  it("sets closed_at timestamp", () => {
    const before = new Date().toISOString();
    const task = ctx.taskStore.create({ title: "Timestamp Close" });
    ctx.taskStore.close(task.id);
    const after = new Date().toISOString();
    const updated = ctx.taskStore.get(task.id);
    expect(updated?.closed_at).toBeTruthy();
    expect(updated?.closed_at! >= before).toBe(true);
    expect(updated?.closed_at! <= after).toBe(true);
  });
});

// ── NativeTaskStore.addDependency() + hasCyclicDependency() ───────────────────

describe("NativeTaskStore.addDependency() and hasCyclicDependency()", () => {
  let ctx: ReturnType<typeof setupStore>;
  let taskA: TaskRow;
  let taskB: TaskRow;
  let taskC: TaskRow;

  beforeEach(() => {
    ctx = setupStore();
    taskA = ctx.taskStore.create({ title: "Task A" });
    taskB = ctx.taskStore.create({ title: "Task B" });
    taskC = ctx.taskStore.create({ title: "Task C" });
  });
  afterEach(() => teardownStore(ctx));

  it("adds a blocks dependency without error", () => {
    expect(() =>
      ctx.taskStore.addDependency(taskA.id, taskB.id, "blocks"),
    ).not.toThrow();
  });

  it("adds a parent-child dependency without error", () => {
    expect(() =>
      ctx.taskStore.addDependency(taskA.id, taskB.id, "parent-child"),
    ).not.toThrow();
  });

  it("throws CircularDependencyError for self-dependency", () => {
    expect(() =>
      ctx.taskStore.addDependency(taskA.id, taskA.id, "blocks"),
    ).toThrow(CircularDependencyError);
  });

  it("throws CircularDependencyError for direct cycle A→B then B→A", () => {
    ctx.taskStore.addDependency(taskA.id, taskB.id, "blocks");
    expect(() =>
      ctx.taskStore.addDependency(taskB.id, taskA.id, "blocks"),
    ).toThrow(CircularDependencyError);
  });

  it("throws CircularDependencyError for transitive cycle A→B→C then C→A", () => {
    ctx.taskStore.addDependency(taskA.id, taskB.id, "blocks");
    ctx.taskStore.addDependency(taskB.id, taskC.id, "blocks");
    expect(() =>
      ctx.taskStore.addDependency(taskC.id, taskA.id, "blocks"),
    ).toThrow(CircularDependencyError);
  });

  it("throws TaskNotFoundError for unknown from-task", () => {
    expect(() =>
      ctx.taskStore.addDependency("00000000-0000-0000-0000-000000000000", taskB.id),
    ).toThrow(TaskNotFoundError);
  });

  it("throws TaskNotFoundError for unknown to-task", () => {
    expect(() =>
      ctx.taskStore.addDependency(taskA.id, "00000000-0000-0000-0000-000000000000"),
    ).toThrow(TaskNotFoundError);
  });

  it("hasCyclicDependency returns false for non-circular relationship", () => {
    ctx.taskStore.addDependency(taskA.id, taskB.id, "blocks");
    // Adding B→C would not create a cycle
    expect(ctx.taskStore.hasCyclicDependency(taskB.id, taskC.id)).toBe(false);
  });

  it("hasCyclicDependency returns true when cycle would exist", () => {
    ctx.taskStore.addDependency(taskA.id, taskB.id, "blocks");
    ctx.taskStore.addDependency(taskB.id, taskC.id, "blocks");
    // Adding C→A would create a cycle
    expect(ctx.taskStore.hasCyclicDependency(taskC.id, taskA.id)).toBe(true);
  });

  it("ignores duplicate dependencies (OR IGNORE)", () => {
    ctx.taskStore.addDependency(taskA.id, taskB.id, "blocks");
    expect(() =>
      ctx.taskStore.addDependency(taskA.id, taskB.id, "blocks"),
    ).not.toThrow();
  });
});

// ── NativeTaskStore.getDependencies() ─────────────────────────────────────────

describe("NativeTaskStore.getDependencies()", () => {
  let ctx: ReturnType<typeof setupStore>;
  let taskA: TaskRow;
  let taskB: TaskRow;
  let taskC: TaskRow;

  beforeEach(() => {
    ctx = setupStore();
    taskA = ctx.taskStore.create({ title: "Task A" });
    taskB = ctx.taskStore.create({ title: "Task B" });
    taskC = ctx.taskStore.create({ title: "Task C" });
    // A blocks B, A parent-child C
    ctx.taskStore.addDependency(taskA.id, taskB.id, "blocks");
    ctx.taskStore.addDependency(taskA.id, taskC.id, "parent-child");
  });
  afterEach(() => teardownStore(ctx));

  it("outgoing returns tasks that A blocks/parents", () => {
    const deps = ctx.taskStore.getDependencies(taskA.id, "outgoing");
    expect(deps.length).toBe(2);
    const toIds = deps.map((d) => d.to_task_id);
    expect(toIds).toContain(taskB.id);
    expect(toIds).toContain(taskC.id);
  });

  it("incoming returns tasks that block B", () => {
    const deps = ctx.taskStore.getDependencies(taskB.id, "incoming");
    expect(deps.length).toBe(1);
    expect(deps[0]!.from_task_id).toBe(taskA.id);
    expect(deps[0]!.type).toBe("blocks");
  });

  it("returns empty array for task with no dependencies", () => {
    const taskD = ctx.taskStore.create({ title: "Task D" });
    expect(ctx.taskStore.getDependencies(taskD.id, "outgoing")).toHaveLength(0);
    expect(ctx.taskStore.getDependencies(taskD.id, "incoming")).toHaveLength(0);
  });
});

// ── NativeTaskStore.removeDependency() ───────────────────────────────────────

describe("NativeTaskStore.removeDependency()", () => {
  let ctx: ReturnType<typeof setupStore>;
  let taskA: TaskRow;
  let taskB: TaskRow;

  beforeEach(() => {
    ctx = setupStore();
    taskA = ctx.taskStore.create({ title: "Task A" });
    taskB = ctx.taskStore.create({ title: "Task B" });
    ctx.taskStore.addDependency(taskA.id, taskB.id, "blocks");
  });
  afterEach(() => teardownStore(ctx));

  it("removes an existing dependency", () => {
    ctx.taskStore.removeDependency(taskA.id, taskB.id, "blocks");
    const deps = ctx.taskStore.getDependencies(taskA.id, "outgoing");
    expect(deps).toHaveLength(0);
  });

  it("is a no-op for non-existent dependency", () => {
    expect(() =>
      ctx.taskStore.removeDependency(taskB.id, taskA.id, "blocks"),
    ).not.toThrow();
  });

  it("after removal, cycle no longer prevents re-adding in reverse", () => {
    // A blocks B — remove it
    ctx.taskStore.removeDependency(taskA.id, taskB.id, "blocks");
    // Now B blocks A should be possible (no cycle)
    expect(() =>
      ctx.taskStore.addDependency(taskB.id, taskA.id, "blocks"),
    ).not.toThrow();
  });
});

// ── NativeTaskStore.hasNativeTasks() ─────────────────────────────────────────

describe("NativeTaskStore.hasNativeTasks()", () => {
  let ctx: ReturnType<typeof setupStore>;

  beforeEach(() => {
    ctx = setupStore();
  });
  afterEach(() => teardownStore(ctx));

  it("returns false when no tasks exist", () => {
    expect(ctx.taskStore.hasNativeTasks()).toBe(false);
  });

  it("returns true after creating a task", () => {
    ctx.taskStore.create({ title: "Existence Test" });
    expect(ctx.taskStore.hasNativeTasks()).toBe(true);
  });
});

// ── NativeTaskStore.updatePhase() ────────────────────────────────────────────

describe("NativeTaskStore.updatePhase()", () => {
  let ctx: ReturnType<typeof setupStore>;

  beforeEach(() => {
    ctx = setupStore();
  });
  afterEach(() => teardownStore(ctx));

  it("updates the status of a task by taskId", () => {
    const task = ctx.taskStore.create({ title: "Phase Test" });
    ctx.taskStore.updatePhase(task.id, "explorer");
    const updated = ctx.taskStore.get(task.id);
    expect(updated?.status).toBe("explorer");
  });

  it("is a no-op when taskId is null", () => {
    // Should not throw
    expect(() => ctx.taskStore.updatePhase(null, "developer")).not.toThrow();
  });

  it("is a no-op when taskId is undefined", () => {
    expect(() => ctx.taskStore.updatePhase(undefined, "developer")).not.toThrow();
  });
});

// ── NativeTaskStore.claim() ───────────────────────────────────────────────────

describe("NativeTaskStore.claim()", () => {
  let ctx: ReturnType<typeof setupStore>;
  let runId1: string;
  let runId2: string;

  beforeEach(() => {
    ctx = setupStore();
    // Create a project and two runs for FK compliance
    const project = ctx.store.registerProject("test-proj", "/tmp/test-proj");
    const run1 = ctx.store.createRun(project.id, "seed-001", "runner");
    const run2 = ctx.store.createRun(project.id, "seed-001", "runner");
    runId1 = run1.id;
    runId2 = run2.id;
  });
  afterEach(() => teardownStore(ctx));

  it("claims a task by setting status=in-progress and run_id", () => {
    const task = ctx.taskStore.create({ title: "Claimable" });
    ctx.taskStore.approve(task.id);
    ctx.taskStore.claim(task.id, runId1);
    const updated = ctx.taskStore.get(task.id);
    expect(updated?.status).toBe("in-progress");
    expect(updated?.run_id).toBe(runId1);
  });

  it("is idempotent for same run claiming same task", () => {
    const task = ctx.taskStore.create({ title: "Idempotent Claim" });
    ctx.taskStore.claim(task.id, runId1);
    expect(() => ctx.taskStore.claim(task.id, runId1)).not.toThrow();
  });

  it("throws for task already claimed by different run", () => {
    const task = ctx.taskStore.create({ title: "Contested Task" });
    ctx.taskStore.claim(task.id, runId1);
    expect(() => ctx.taskStore.claim(task.id, runId2)).toThrow();
  });

  it("throws for unknown task", () => {
    expect(() =>
      ctx.taskStore.claim("00000000-0000-0000-0000-000000000000", runId1),
    ).toThrow();
  });
});

// ── NativeTaskStore.list() ────────────────────────────────────────────────────

describe("NativeTaskStore.list()", () => {
  let ctx: ReturnType<typeof setupStore>;

  beforeEach(() => {
    ctx = setupStore();
    // Create tasks with different statuses
    const t1 = ctx.taskStore.create({ title: "Task 1", priority: 2 });
    const t2 = ctx.taskStore.create({ title: "Task 2", priority: 1 });
    ctx.taskStore.create({ title: "Task 3", priority: 0 }); // stays backlog
    ctx.taskStore.approve(t1.id);
    ctx.taskStore.approve(t2.id);
  });
  afterEach(() => teardownStore(ctx));

  it("returns all tasks when no filter provided", () => {
    const tasks = ctx.taskStore.list();
    expect(tasks.length).toBe(3);
  });

  it("filters by status=ready", () => {
    const readyTasks = ctx.taskStore.list({ status: "ready" });
    expect(readyTasks.length).toBe(2);
    expect(readyTasks.every((t) => t.status === "ready")).toBe(true);
  });

  it("returns tasks ordered by priority ASC then created_at ASC", () => {
    const tasks = ctx.taskStore.list({ status: "ready" });
    // priority 1 < priority 2
    expect(tasks[0]?.title).toBe("Task 2");
    expect(tasks[1]?.title).toBe("Task 1");
  });

  it("returns empty array when no tasks match filter", () => {
    const mergedTasks = ctx.taskStore.list({ status: "merged" });
    expect(mergedTasks).toHaveLength(0);
  });
});

// ── Dependency Row Verification ───────────────────────────────────────────────

describe("Dependency row verification", () => {
  let ctx: ReturnType<typeof setupStore>;
  let taskA: TaskRow;
  let taskB: TaskRow;

  beforeEach(() => {
    ctx = setupStore();
    taskA = ctx.taskStore.create({ title: "Task A" });
    taskB = ctx.taskStore.create({ title: "Task B" });
  });
  afterEach(() => teardownStore(ctx));

  it("stores blocks row with correct from/to after addDependency", () => {
    ctx.taskStore.addDependency(taskA.id, taskB.id, "blocks");
    const deps = ctx.taskStore.getDependencies(taskA.id, "outgoing");
    expect(deps).toHaveLength(1);
    expect(deps[0]!).toMatchObject({
      from_task_id: taskA.id,
      to_task_id: taskB.id,
      type: "blocks",
    } as DependencyRow);
  });

  it("stores parent-child row with correct type after addDependency", () => {
    ctx.taskStore.addDependency(taskA.id, taskB.id, "parent-child");
    const deps = ctx.taskStore.getDependencies(taskA.id, "outgoing");
    expect(deps).toHaveLength(1);
    expect(deps[0]!.type).toBe("parent-child");
  });

  it("blocks row appears in incoming query of the blocker", () => {
    ctx.taskStore.addDependency(taskA.id, taskB.id, "blocks");
    const incoming = ctx.taskStore.getDependencies(taskB.id, "incoming");
    expect(incoming).toHaveLength(1);
    expect(incoming[0]!.from_task_id).toBe(taskA.id);
    expect(incoming[0]!.type).toBe("blocks");
  });
});

// ── Cascade Unblock (reevaluateBlockedTasks) ──────────────────────────────────

describe("NativeTaskStore.reevaluateBlockedTasks()", () => {
  let ctx: ReturnType<typeof setupStore>;
  let taskA: TaskRow;
  let taskB: TaskRow;
  let taskC: TaskRow;

  beforeEach(() => {
    ctx = setupStore();
    taskA = ctx.taskStore.create({ title: "Task A" });
    taskB = ctx.taskStore.create({ title: "Task B" });
    taskC = ctx.taskStore.create({ title: "Task C" });
  });
  afterEach(() => teardownStore(ctx));

  it("transitions blocked→ready when all blockers merged", () => {
    // Setup: A is blocked by B
    ctx.taskStore.addDependency(taskA.id, taskB.id, "blocks");
    // Manually set A to blocked (dispatcher does this)
    ctx.store.getDb().prepare("UPDATE tasks SET status='blocked' WHERE id=?").run(taskA.id);
    // Approve and close the blocker
    ctx.taskStore.approve(taskB.id);
    ctx.taskStore.close(taskB.id);
    // Re-evaluate
    ctx.taskStore.reevaluateBlockedTasks();
    // Verify
    const updated = ctx.taskStore.get(taskA.id);
    expect(updated?.status).toBe("ready");
  });

  it("does not unblock when any blocker is still open", () => {
    // A blocked by B and C
    ctx.taskStore.addDependency(taskA.id, taskB.id, "blocks");
    ctx.taskStore.addDependency(taskA.id, taskC.id, "blocks");
    ctx.store.getDb().prepare("UPDATE tasks SET status='blocked' WHERE id=?").run(taskA.id);
    // Only close B, leave C open
    ctx.taskStore.approve(taskB.id);
    ctx.taskStore.close(taskB.id);
    ctx.taskStore.reevaluateBlockedTasks();
    // A should still be blocked
    const updated = ctx.taskStore.get(taskA.id);
    expect(updated?.status).toBe("blocked");
  });

  it("unblocks when all multiple blockers are merged", () => {
    // A blocked by B and C
    ctx.taskStore.addDependency(taskA.id, taskB.id, "blocks");
    ctx.taskStore.addDependency(taskA.id, taskC.id, "blocks");
    ctx.store.getDb().prepare("UPDATE tasks SET status='blocked' WHERE id=?").run(taskA.id);
    // Close both blockers
    ctx.taskStore.approve(taskB.id);
    ctx.taskStore.close(taskB.id);
    ctx.taskStore.approve(taskC.id);
    ctx.taskStore.close(taskC.id);
    ctx.taskStore.reevaluateBlockedTasks();
    // A should now be ready
    const updated = ctx.taskStore.get(taskA.id);
    expect(updated?.status).toBe("ready");
  });

  it("is a no-op when no tasks are blocked", () => {
    // No tasks are blocked - should not throw
    expect(() => ctx.taskStore.reevaluateBlockedTasks()).not.toThrow();
  });

  it("parent-child dependency does not affect blocking", () => {
    // Add parent-child relationship: A parent-child B
    ctx.taskStore.addDependency(taskA.id, taskB.id, "parent-child");
    // A is in backlog, B is closed - A should NOT be affected
    ctx.taskStore.approve(taskB.id);
    ctx.taskStore.close(taskB.id);
    ctx.taskStore.reevaluateBlockedTasks();
    // A should remain in whatever status it was (backlog, unchanged)
    const updated = ctx.taskStore.get(taskA.id);
    expect(updated?.status).toBe("backlog");
  });

  it("approved-only unblock: unblocked task transitions to ready with approved_at set", () => {
    // A starts in backlog (not approved), then is marked blocked
    ctx.store.getDb().prepare("UPDATE tasks SET status='blocked' WHERE id=?").run(taskA.id);
    ctx.taskStore.addDependency(taskA.id, taskB.id, "blocks");
    ctx.taskStore.approve(taskB.id);
    ctx.taskStore.close(taskB.id);
    const before = new Date().toISOString();
    ctx.taskStore.reevaluateBlockedTasks();
    const after = new Date().toISOString();
    // When unblocked, status transitions to ready AND approved_at is set
    // (so the task is treated as approved — matches approve() semantics)
    const updated = ctx.taskStore.get(taskA.id);
    expect(updated?.status).toBe("ready");
    expect(updated?.approved_at).toBeTruthy();
    expect(updated?.approved_at! >= before).toBe(true);
    expect(updated?.approved_at! <= after).toBe(true);
  });

  it("does not overwrite approved_at when task was already approved before being blocked", () => {
    // A is approved first, then marked blocked
    ctx.taskStore.approve(taskA.id);
    const originalApprovedAt = ctx.taskStore.get(taskA.id)?.approved_at;
    expect(originalApprovedAt).toBeTruthy();
    // Mark A as blocked
    ctx.store.getDb().prepare("UPDATE tasks SET status='blocked' WHERE id=?").run(taskA.id);
    ctx.taskStore.addDependency(taskA.id, taskB.id, "blocks");
    ctx.taskStore.approve(taskB.id);
    ctx.taskStore.close(taskB.id);
    ctx.taskStore.reevaluateBlockedTasks();
    // approved_at should be preserved (not overwritten with a new timestamp)
    const updated = ctx.taskStore.get(taskA.id);
    expect(updated?.status).toBe("ready");
    expect(updated?.approved_at).toBe(originalApprovedAt);
  });
});
