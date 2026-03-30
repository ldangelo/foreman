/**
 * Tests for NativeTaskStore.
 *
 * REQ-014 — coexistence check via hasNativeTasks()
 * REQ-017 — dispatcher native store: SELECT WHERE status=ready
 * REQ-020 — atomic claim, backward-compatible null taskId
 */

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ForemanStore } from "../store.js";
import { NativeTaskStore } from "../task-store.js";
import { randomUUID } from "node:crypto";

// ── Helpers ──────────────────────────────────────────────────────────────

function makeTmpDir() {
  return mkdtempSync(join(tmpdir(), "foreman-task-store-test-"));
}

function makeStores(tmpDir: string) {
  const foremanStore = new ForemanStore(join(tmpDir, "foreman.db"));
  const taskStore = new NativeTaskStore(foremanStore.getDb());
  return { foremanStore, taskStore };
}

function insertTask(
  db: ReturnType<ForemanStore["getDb"]>,
  opts: Partial<{
    id: string;
    title: string;
    status: string;
    priority: number;
    type: string;
  }> = {},
) {
  const id = opts.id ?? randomUUID();
  const now = new Date().toISOString();
  db.prepare(
    `INSERT INTO tasks (id, title, description, type, priority, status, created_at, updated_at)
     VALUES (?, ?, NULL, ?, ?, ?, ?, ?)`,
  ).run(
    id,
    opts.title ?? "Test Task",
    opts.type ?? "task",
    opts.priority ?? 2,
    opts.status ?? "ready",
    now,
    now,
  );
  return id;
}

// ── Test suite ───────────────────────────────────────────────────────────

describe("NativeTaskStore.hasNativeTasks()", () => {
  let tmpDir: string;
  let foremanStore: ForemanStore;
  let taskStore: NativeTaskStore;

  beforeEach(() => {
    tmpDir = makeTmpDir();
    ({ foremanStore, taskStore } = makeStores(tmpDir));
  });

  afterEach(() => {
    foremanStore.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("returns false when tasks table is empty", () => {
    expect(taskStore.hasNativeTasks()).toBe(false);
  });

  it("returns true when at least one task exists", () => {
    insertTask(foremanStore.getDb());
    expect(taskStore.hasNativeTasks()).toBe(true);
  });

  it("returns false after all tasks are deleted", () => {
    const id = insertTask(foremanStore.getDb());
    expect(taskStore.hasNativeTasks()).toBe(true);
    foremanStore.getDb().prepare("DELETE FROM tasks WHERE id = ?").run(id);
    expect(taskStore.hasNativeTasks()).toBe(false);
  });
});

describe("NativeTaskStore.list()", () => {
  let tmpDir: string;
  let foremanStore: ForemanStore;
  let taskStore: NativeTaskStore;

  beforeEach(() => {
    tmpDir = makeTmpDir();
    ({ foremanStore, taskStore } = makeStores(tmpDir));
  });

  afterEach(() => {
    foremanStore.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("returns all tasks when no filter is provided", () => {
    const db = foremanStore.getDb();
    insertTask(db, { status: "ready" });
    insertTask(db, { status: "in-progress" });
    insertTask(db, { status: "backlog" });

    const tasks = taskStore.list();
    expect(tasks).toHaveLength(3);
  });

  it("filters by status when opts.status is provided", () => {
    const db = foremanStore.getDb();
    insertTask(db, { status: "ready", title: "R1" });
    insertTask(db, { status: "ready", title: "R2" });
    insertTask(db, { status: "in-progress", title: "IP1" });

    const readyTasks = taskStore.list({ status: "ready" });
    expect(readyTasks).toHaveLength(2);
    expect(readyTasks.every((t) => t.status === "ready")).toBe(true);
  });

  it("returns an empty array when no tasks match the filter", () => {
    const db = foremanStore.getDb();
    insertTask(db, { status: "backlog" });

    const readyTasks = taskStore.list({ status: "ready" });
    expect(readyTasks).toHaveLength(0);
  });

  it("maps task rows to Issue objects", () => {
    const db = foremanStore.getDb();
    const id = insertTask(db, { title: "My Task", status: "ready", priority: 1, type: "bug" });

    const tasks = taskStore.list({ status: "ready" });
    expect(tasks).toHaveLength(1);
    const task = tasks[0];
    expect(task.id).toBe(id);
    expect(task.title).toBe("My Task");
    expect(task.status).toBe("ready");
    expect(task.priority).toBe("1");
    expect(task.type).toBe("bug");
    expect(task.assignee).toBeNull();
    expect(task.parent).toBeNull();
  });

  it("sorts by priority ASC, then created_at ASC", () => {
    const db = foremanStore.getDb();
    // Insert in reverse priority order
    const idLow = insertTask(db, { priority: 3, title: "Low" });
    const idHigh = insertTask(db, { priority: 0, title: "High" });
    const idMed = insertTask(db, { priority: 2, title: "Med" });

    const tasks = taskStore.list();
    expect(tasks[0].id).toBe(idHigh);  // priority 0
    expect(tasks[1].id).toBe(idMed);   // priority 2
    expect(tasks[2].id).toBe(idLow);   // priority 3
  });
});

describe("NativeTaskStore.claim()", () => {
  let tmpDir: string;
  let foremanStore: ForemanStore;
  let taskStore: NativeTaskStore;

  beforeEach(() => {
    tmpDir = makeTmpDir();
    ({ foremanStore, taskStore } = makeStores(tmpDir));
  });

  afterEach(() => {
    foremanStore.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  /**
   * Insert a minimal run record to satisfy the FK constraint on tasks.run_id.
   * The project_id is "proj-test" (no FK on projects in this minimal setup).
   */
  function insertRun(db: ReturnType<ForemanStore["getDb"]>, runId: string) {
    // Disable FK enforcement temporarily to insert without a matching project.
    db.pragma("foreign_keys = OFF");
    const now = new Date().toISOString();
    db.prepare(
      `INSERT INTO runs (id, project_id, seed_id, agent_type, status, created_at)
       VALUES (?, 'proj-test', 'seed-test', 'claude-code', 'running', ?)`,
    ).run(runId, now);
    db.pragma("foreign_keys = ON");
  }

  it("sets status to in-progress and records run_id", () => {
    const db = foremanStore.getDb();
    const id = insertTask(db, { status: "ready" });
    const runId = "run-123";
    insertRun(db, runId);

    taskStore.claim(id, runId);

    const row = db.prepare("SELECT status, run_id FROM tasks WHERE id = ?").get(id) as
      | { status: string; run_id: string | null }
      | undefined;
    expect(row?.status).toBe("in-progress");
    expect(row?.run_id).toBe(runId);
  });

  it("is idempotent when called again with the same runId", () => {
    const db = foremanStore.getDb();
    const id = insertTask(db, { status: "ready" });
    const runId = "run-123";
    insertRun(db, runId);

    taskStore.claim(id, runId);
    // Calling again with the same runId should not throw
    expect(() => taskStore.claim(id, runId)).not.toThrow();
  });

  it("throws when the task is already claimed by a different run", () => {
    const db = foremanStore.getDb();
    const id = insertTask(db, { status: "ready" });
    insertRun(db, "run-111");
    insertRun(db, "run-222");

    taskStore.claim(id, "run-111");
    expect(() => taskStore.claim(id, "run-222")).toThrow(/already claimed/);
  });

  it("throws when the task does not exist", () => {
    expect(() => taskStore.claim("nonexistent-task", "run-xyz")).toThrow(/not found/);
  });

  it("updates updated_at timestamp", () => {
    const db = foremanStore.getDb();
    const id = insertTask(db, { status: "ready" });
    const runId = "run-001";
    insertRun(db, runId);
    const before = new Date().toISOString();

    taskStore.claim(id, runId);

    const row = db.prepare("SELECT updated_at FROM tasks WHERE id = ?").get(id) as
      | { updated_at: string }
      | undefined;
    expect(row?.updated_at).toBeDefined();
    expect(row!.updated_at >= before).toBe(true);
  });
});

describe("NativeTaskStore.updatePhase()", () => {
  let tmpDir: string;
  let foremanStore: ForemanStore;
  let taskStore: NativeTaskStore;

  beforeEach(() => {
    tmpDir = makeTmpDir();
    ({ foremanStore, taskStore } = makeStores(tmpDir));
  });

  afterEach(() => {
    foremanStore.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("updates the task status to the given phase", () => {
    const db = foremanStore.getDb();
    const id = insertTask(db, { status: "in-progress" });

    taskStore.updatePhase(id, "developer");

    const row = db.prepare("SELECT status FROM tasks WHERE id = ?").get(id) as
      | { status: string }
      | undefined;
    expect(row?.status).toBe("developer");
  });

  it("is a no-op when taskId is null (beads fallback mode)", () => {
    // Should not throw and should not touch any rows
    const db = foremanStore.getDb();
    const id = insertTask(db, { status: "in-progress" });

    expect(() => taskStore.updatePhase(null, "developer")).not.toThrow();

    const row = db.prepare("SELECT status FROM tasks WHERE id = ?").get(id) as
      | { status: string }
      | undefined;
    expect(row?.status).toBe("in-progress"); // unchanged
  });
});

describe("NativeTaskStore.updateStatus()", () => {
  let tmpDir: string;
  let foremanStore: ForemanStore;
  let taskStore: NativeTaskStore;

  beforeEach(() => {
    tmpDir = makeTmpDir();
    ({ foremanStore, taskStore } = makeStores(tmpDir));
  });

  afterEach(() => {
    foremanStore.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("updates the task status", () => {
    const db = foremanStore.getDb();
    const id = insertTask(db, { status: "in-progress" });

    taskStore.updateStatus(id, "merged");

    const row = db.prepare("SELECT status FROM tasks WHERE id = ?").get(id) as
      | { status: string }
      | undefined;
    expect(row?.status).toBe("merged");
  });
});
