/**
 * Tests for `foreman task` CLI commands.
 *
 * Covers:
 *   - `foreman task create` — required options, priority aliases, type validation
 *   - `foreman task list` — empty store, with tasks, status filter
 *   - `foreman task show` — existing task, not-found error
 *   - `foreman task approve` — backlog → ready, already-approved error
 *   - `foreman task close` — close task, not-found error
 *   - `foreman task dep add` — add dependency, cycle detection, duplicate
 *   - `foreman task dep list` — list dependencies
 *   - `foreman task dep remove` — remove dependency
 *
 * Uses NativeTaskStore directly (no subprocess) for speed.
 */

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ForemanStore } from "../../lib/store.js";
import {
  NativeTaskStore,
  parsePriority,
  priorityLabel,
  TaskNotFoundError,
  InvalidStatusTransitionError,
  CircularDependencyError,
  type TaskRow,
} from "../../lib/task-store.js";

// ── Test helpers ──────────────────────────────────────────────────────────────

function setupStore(): { store: ForemanStore; taskStore: NativeTaskStore; tmpDir: string } {
  const tmpDir = mkdtempSync(join(tmpdir(), "foreman-task-cli-test-"));
  mkdirSync(join(tmpDir, ".foreman"), { recursive: true });
  const dbPath = join(tmpDir, ".foreman", "foreman.db");
  const store = new ForemanStore(dbPath);
  const taskStore = new NativeTaskStore(store.getDb());
  return { store, taskStore, tmpDir };
}

function teardownStore(ctx: { store: ForemanStore; tmpDir: string }): void {
  ctx.store.close();
  rmSync(ctx.tmpDir, { recursive: true, force: true });
}

// ── foreman task create (via NativeTaskStore.create directly) ─────────────────

describe("task create — NativeTaskStore.create()", () => {
  let ctx: ReturnType<typeof setupStore>;

  beforeEach(() => {
    ctx = setupStore();
  });
  afterEach(() => teardownStore(ctx));

  it("creates a task with default values", () => {
    const task = ctx.taskStore.create({ title: "Default Task" });
    expect(task.title).toBe("Default Task");
    expect(task.status).toBe("backlog");
    expect(task.type).toBe("task");
    expect(task.priority).toBe(2); // medium
  });

  it("creates a task with all options specified", () => {
    const task = ctx.taskStore.create({
      title: "Full Task",
      description: "A description",
      type: "bug",
      priority: 0,
    });
    expect(task.type).toBe("bug");
    expect(task.priority).toBe(0);
    expect(task.description).toBe("A description");
  });

  it("parsePriority converts 'critical' to 0", () => {
    expect(parsePriority("critical")).toBe(0);
  });

  it("parsePriority converts 'high' to 1", () => {
    expect(parsePriority("high")).toBe(1);
  });

  it("parsePriority converts 'medium' to 2", () => {
    expect(parsePriority("medium")).toBe(2);
  });

  it("parsePriority converts 'low' to 3", () => {
    expect(parsePriority("low")).toBe(3);
  });

  it("parsePriority converts 'backlog' to 4", () => {
    expect(parsePriority("backlog")).toBe(4);
  });

  it("parsePriority accepts numeric '0'–'4'", () => {
    for (let i = 0; i <= 4; i++) {
      expect(parsePriority(String(i))).toBe(i);
    }
  });

  it("parsePriority throws for invalid string", () => {
    expect(() => parsePriority("urgent")).toThrow(RangeError);
  });

  it("priorityLabel converts 0–4 back to labels", () => {
    expect(priorityLabel(0)).toBe("critical");
    expect(priorityLabel(4)).toBe("backlog");
  });
});

// ── foreman task list ─────────────────────────────────────────────────────────

describe("task list — NativeTaskStore.list()", () => {
  let ctx: ReturnType<typeof setupStore>;

  beforeEach(() => {
    ctx = setupStore();
  });
  afterEach(() => teardownStore(ctx));

  it("returns empty list when no tasks exist", () => {
    expect(ctx.taskStore.list()).toHaveLength(0);
  });

  it("returns all tasks without filter", () => {
    ctx.taskStore.create({ title: "Task 1" });
    ctx.taskStore.create({ title: "Task 2" });
    expect(ctx.taskStore.list()).toHaveLength(2);
  });

  it("filters by status=backlog", () => {
    ctx.taskStore.create({ title: "Backlog Task" });
    const t2 = ctx.taskStore.create({ title: "Ready Task" });
    ctx.taskStore.approve(t2.id);
    const backlog = ctx.taskStore.list({ status: "backlog" });
    expect(backlog).toHaveLength(1);
    expect(backlog[0]!.title).toBe("Backlog Task");
  });

  it("filters by status=ready", () => {
    ctx.taskStore.create({ title: "Still Backlog" });
    const t2 = ctx.taskStore.create({ title: "Ready Now" });
    ctx.taskStore.approve(t2.id);
    const ready = ctx.taskStore.list({ status: "ready" });
    expect(ready).toHaveLength(1);
    expect(ready[0]!.title).toBe("Ready Now");
  });

  it("orders by priority ASC then created_at ASC", () => {
    const t1 = ctx.taskStore.create({ title: "Low Pri", priority: 3 });
    const t2 = ctx.taskStore.create({ title: "High Pri", priority: 1 });
    ctx.taskStore.approve(t1.id);
    ctx.taskStore.approve(t2.id);
    const ready = ctx.taskStore.list({ status: "ready" });
    expect(ready[0]!.title).toBe("High Pri");
    expect(ready[1]!.title).toBe("Low Pri");
  });
});

// ── foreman task show ─────────────────────────────────────────────────────────

describe("task show — NativeTaskStore.get()", () => {
  let ctx: ReturnType<typeof setupStore>;

  beforeEach(() => {
    ctx = setupStore();
  });
  afterEach(() => teardownStore(ctx));

  it("returns task for existing ID", () => {
    const task = ctx.taskStore.create({ title: "Show Me" });
    const found = ctx.taskStore.get(task.id);
    expect(found).not.toBeNull();
    expect(found!.title).toBe("Show Me");
  });

  it("returns null for non-existent ID", () => {
    expect(ctx.taskStore.get("00000000-0000-0000-0000-000000000000")).toBeNull();
  });
});

// ── foreman task approve ──────────────────────────────────────────────────────

describe("task approve — NativeTaskStore.approve()", () => {
  let ctx: ReturnType<typeof setupStore>;

  beforeEach(() => {
    ctx = setupStore();
  });
  afterEach(() => teardownStore(ctx));

  it("transitions backlog to ready", () => {
    const task = ctx.taskStore.create({ title: "Approve Test" });
    ctx.taskStore.approve(task.id);
    expect(ctx.taskStore.get(task.id)?.status).toBe("ready");
  });

  it("sets approved_at timestamp", () => {
    const task = ctx.taskStore.create({ title: "Timestamp" });
    ctx.taskStore.approve(task.id);
    expect(ctx.taskStore.get(task.id)?.approved_at).toBeTruthy();
  });

  it("throws for non-backlog tasks", () => {
    const task = ctx.taskStore.create({ title: "Already Ready" });
    ctx.taskStore.approve(task.id);
    // Approving again should throw (not in backlog)
    expect(() => ctx.taskStore.approve(task.id)).toThrow();
  });

  it("throws TaskNotFoundError for unknown ID", () => {
    expect(() =>
      ctx.taskStore.approve("00000000-0000-0000-0000-000000000000"),
    ).toThrow(TaskNotFoundError);
  });
});

// ── foreman task update ────────────────────────────────────────────────────────

describe("task update — NativeTaskStore.update()", () => {
  let ctx: ReturnType<typeof setupStore>;

  beforeEach(() => {
    ctx = setupStore();
  });
  afterEach(() => teardownStore(ctx));

  it("updates title", () => {
    const task = ctx.taskStore.create({ title: "Original Title" });
    const updated = ctx.taskStore.update(task.id, { title: "New Title" });
    expect(updated.title).toBe("New Title");
  });

  it("updates description", () => {
    const task = ctx.taskStore.create({ title: "With Desc" });
    const updated = ctx.taskStore.update(task.id, { description: "New description" });
    expect(updated.description).toBe("New description");
  });

  it("clears description when set to null", () => {
    const task = ctx.taskStore.create({ title: "With Desc", description: "Old" });
    const updated = ctx.taskStore.update(task.id, { description: null });
    expect(updated.description).toBeNull();
  });

  it("updates priority", () => {
    const task = ctx.taskStore.create({ title: "Pri Task", priority: 2 });
    const updated = ctx.taskStore.update(task.id, { priority: 0 });
    expect(updated.priority).toBe(0);
  });

  it("updates status forward without --force", () => {
    const task = ctx.taskStore.create({ title: "Status Task" });
    ctx.taskStore.approve(task.id);
    const updated = ctx.taskStore.update(task.id, { status: "in-progress" });
    expect(updated.status).toBe("in-progress");
  });

  it("throws InvalidStatusTransitionError for backward transition without --force", () => {
    const task = ctx.taskStore.create({ title: "Backward Test" });
    ctx.taskStore.approve(task.id); // ready
    expect(() => ctx.taskStore.update(task.id, { status: "backlog" })).toThrow(
      InvalidStatusTransitionError,
    );
  });

  it("allows backward transition with --force", () => {
    const task = ctx.taskStore.create({ title: "Force Test" });
    ctx.taskStore.approve(task.id); // ready
    const updated = ctx.taskStore.update(task.id, { status: "backlog", force: true });
    expect(updated.status).toBe("backlog");
  });

  it("throws TaskNotFoundError for unknown ID", () => {
    expect(() =>
      ctx.taskStore.update("00000000-0000-0000-0000-000000000000", { title: "Nope" }),
    ).toThrow(TaskNotFoundError);
  });

  it("returns updated task row", () => {
    const task = ctx.taskStore.create({ title: "Full Update" });
    const updated = ctx.taskStore.update(task.id, {
      title: "Updated Title",
      description: "Updated desc",
      priority: 1,
    });
    expect(updated.title).toBe("Updated Title");
    expect(updated.description).toBe("Updated desc");
    expect(updated.priority).toBe(1);
  });
});

// ── foreman task close ────────────────────────────────────────────────────────

describe("task close — NativeTaskStore.close()", () => {
  let ctx: ReturnType<typeof setupStore>;

  beforeEach(() => {
    ctx = setupStore();
  });
  afterEach(() => teardownStore(ctx));

  it("sets status to closed", () => {
    const task = ctx.taskStore.create({ title: "Close Test" });
    ctx.taskStore.close(task.id);
    expect(ctx.taskStore.get(task.id)?.status).toBe("closed");
  });

  it("sets closed_at timestamp", () => {
    const task = ctx.taskStore.create({ title: "Close Timestamp" });
    ctx.taskStore.close(task.id);
    expect(ctx.taskStore.get(task.id)?.closed_at).toBeTruthy();
  });

  it("throws TaskNotFoundError for unknown ID", () => {
    expect(() =>
      ctx.taskStore.close("00000000-0000-0000-0000-000000000000"),
    ).toThrow(TaskNotFoundError);
  });

  it("removes task from ready list after closing", () => {
    const task = ctx.taskStore.create({ title: "Close Gone" });
    ctx.taskStore.approve(task.id);
    ctx.taskStore.close(task.id);
    const ready = ctx.taskStore.list({ status: "ready" });
    expect(ready.every((t) => t.id !== task.id)).toBe(true);
  });
});

// ── foreman task dep add ──────────────────────────────────────────────────────

describe("task dep add — NativeTaskStore.addDependency()", () => {
  let ctx: ReturnType<typeof setupStore>;
  let taskA: TaskRow;
  let taskB: TaskRow;

  beforeEach(() => {
    ctx = setupStore();
    taskA = ctx.taskStore.create({ title: "Task A" });
    taskB = ctx.taskStore.create({ title: "Task B" });
  });
  afterEach(() => teardownStore(ctx));

  it("adds a blocks dependency", () => {
    ctx.taskStore.addDependency(taskA.id, taskB.id, "blocks");
    const deps = ctx.taskStore.getDependencies(taskA.id, "outgoing");
    expect(deps).toHaveLength(1);
    expect(deps[0]!.to_task_id).toBe(taskB.id);
    expect(deps[0]!.type).toBe("blocks");
  });

  it("adds a parent-child dependency", () => {
    ctx.taskStore.addDependency(taskA.id, taskB.id, "parent-child");
    const deps = ctx.taskStore.getDependencies(taskA.id, "outgoing");
    expect(deps[0]!.type).toBe("parent-child");
  });

  it("throws CircularDependencyError for self-dependency", () => {
    expect(() =>
      ctx.taskStore.addDependency(taskA.id, taskA.id),
    ).toThrow(CircularDependencyError);
  });

  it("throws CircularDependencyError for direct cycle", () => {
    ctx.taskStore.addDependency(taskA.id, taskB.id);
    expect(() =>
      ctx.taskStore.addDependency(taskB.id, taskA.id),
    ).toThrow(CircularDependencyError);
  });

  it("throws TaskNotFoundError for unknown task", () => {
    expect(() =>
      ctx.taskStore.addDependency("00000000-0000-0000-0000-000000000000", taskB.id),
    ).toThrow(TaskNotFoundError);
  });
});

// ── foreman task dep list ─────────────────────────────────────────────────────

describe("task dep list — NativeTaskStore.getDependencies()", () => {
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

  it("outgoing: returns tasks that A blocks", () => {
    const deps = ctx.taskStore.getDependencies(taskA.id, "outgoing");
    expect(deps).toHaveLength(1);
    expect(deps[0]!.to_task_id).toBe(taskB.id);
  });

  it("incoming: returns tasks that block B", () => {
    const deps = ctx.taskStore.getDependencies(taskB.id, "incoming");
    expect(deps).toHaveLength(1);
    expect(deps[0]!.from_task_id).toBe(taskA.id);
  });

  it("returns empty arrays for task with no deps", () => {
    const taskC = ctx.taskStore.create({ title: "Task C" });
    expect(ctx.taskStore.getDependencies(taskC.id, "outgoing")).toHaveLength(0);
    expect(ctx.taskStore.getDependencies(taskC.id, "incoming")).toHaveLength(0);
  });
});

// ── foreman task dep remove ───────────────────────────────────────────────────

describe("task dep remove — NativeTaskStore.removeDependency()", () => {
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

  it("removes existing dependency", () => {
    ctx.taskStore.removeDependency(taskA.id, taskB.id, "blocks");
    const deps = ctx.taskStore.getDependencies(taskA.id, "outgoing");
    expect(deps).toHaveLength(0);
  });

  it("is a no-op for non-existent dependency", () => {
    expect(() =>
      ctx.taskStore.removeDependency(taskB.id, taskA.id, "blocks"),
    ).not.toThrow();
  });

  it("allows reverse dependency after removal", () => {
    ctx.taskStore.removeDependency(taskA.id, taskB.id, "blocks");
    expect(() =>
      ctx.taskStore.addDependency(taskB.id, taskA.id, "blocks"),
    ).not.toThrow();
  });
});

// ── taskCommand import ────────────────────────────────────────────────────────

describe("taskCommand export", () => {
  it("taskCommand is exported from task.ts", async () => {
    const { taskCommand } = await import("../commands/task.js");
    expect(taskCommand).toBeDefined();
    expect(taskCommand.name()).toBe("task");
  });

  it("taskCommand has expected subcommands", async () => {
    const { taskCommand } = await import("../commands/task.js");
    const names = taskCommand.commands.map((c) => c.name());
    expect(names).toContain("create");
    expect(names).toContain("list");
    expect(names).toContain("show");
    expect(names).toContain("approve");
    expect(names).toContain("update");
    expect(names).toContain("close");
    expect(names).toContain("dep");
  });

  it("dep subcommand has add/list/remove", async () => {
    const { taskCommand } = await import("../commands/task.js");
    const depCmd = taskCommand.commands.find((c) => c.name() === "dep");
    expect(depCmd).toBeDefined();
    const depSubNames = depCmd!.commands.map((c) => c.name());
    expect(depSubNames).toContain("add");
    expect(depSubNames).toContain("list");
    expect(depSubNames).toContain("remove");
  });
});
