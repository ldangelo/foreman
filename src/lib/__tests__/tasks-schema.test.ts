/**
 * Tests for the tasks / task_dependencies DDL migration and InvalidTaskStatusError.
 *
 * REQ-003 — tasks table with CHECK constraint on status
 * REQ-004 — task_dependencies table for dependency graph
 * REQ-020 — VCS backend integration (external_id for beads migration)
 */

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { randomUUID } from "node:crypto";
import Database from "better-sqlite3";
import { ForemanStore, InvalidTaskStatusError } from "../store.js";

// ── InvalidTaskStatusError ─────────────────────────────────────────────

describe("InvalidTaskStatusError", () => {
  const VALID = [
    "backlog",
    "ready",
    "in-progress",
    "explorer",
    "developer",
    "qa",
    "reviewer",
    "finalize",
    "merged",
    "conflict",
    "failed",
    "stuck",
    "blocked",
  ];

  it("is an instance of Error", () => {
    const err = new InvalidTaskStatusError("unknown", VALID);
    expect(err).toBeInstanceOf(Error);
    expect(err).toBeInstanceOf(InvalidTaskStatusError);
  });

  it("has name InvalidTaskStatusError", () => {
    const err = new InvalidTaskStatusError("bogus", VALID);
    expect(err.name).toBe("InvalidTaskStatusError");
  });

  it("message contains the attempted status", () => {
    const err = new InvalidTaskStatusError("invalid-status", VALID);
    expect(err.message).toContain("invalid-status");
  });

  it("message lists valid statuses", () => {
    const err = new InvalidTaskStatusError("bad", VALID);
    for (const s of VALID) {
      expect(err.message).toContain(s);
    }
  });

  it("exposes attemptedStatus and validStatuses on the instance", () => {
    const err = new InvalidTaskStatusError("nope", VALID);
    expect(err.attemptedStatus).toBe("nope");
    expect(err.validStatuses).toEqual(VALID);
  });
});

// ── DDL migration: tasks table ─────────────────────────────────────────

describe("ForemanStore DDL — tasks table", () => {
  let store: ForemanStore;
  let tmpDir: string;
  let db: Database.Database;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-tasks-test-"));
    const dbPath = join(tmpDir, "test.db");
    store = new ForemanStore(dbPath);
    // Grab a direct DB reference for low-level assertions
    db = store.getDb();
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("creates the tasks table on first open (idempotent)", () => {
    const row = db
      .prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='tasks'")
      .get();
    expect(row).toBeDefined();
  });

  it("tasks table is idempotent across multiple ForemanStore opens", () => {
    store.close();
    const dbPath = join(tmpDir, "test.db");
    // Open a second store against the same DB — should not throw
    const store2 = new ForemanStore(dbPath);
    const row = store2
      .getDb()
      .prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='tasks'")
      .get();
    expect(row).toBeDefined();
    store2.close();
  });

  it("tasks table has required columns", () => {
    const cols = db.prepare("PRAGMA table_info(tasks)").all() as Array<{ name: string }>;
    const names = cols.map((c) => c.name);
    expect(names).toContain("id");
    expect(names).toContain("title");
    expect(names).toContain("description");
    expect(names).toContain("type");
    expect(names).toContain("priority");
    expect(names).toContain("status");
    expect(names).toContain("run_id");
    expect(names).toContain("branch");
    expect(names).toContain("external_id");
    expect(names).toContain("created_at");
    expect(names).toContain("updated_at");
    expect(names).toContain("approved_at");
    expect(names).toContain("closed_at");
  });

  it("tasks table accepts all valid status values", () => {
    const now = new Date().toISOString();
    const validStatuses = [
      "backlog",
      "ready",
      "in-progress",
      "explorer",
      "developer",
      "qa",
      "reviewer",
      "finalize",
      "merged",
      "conflict",
      "failed",
      "stuck",
      "blocked",
    ];
    const insert = db.prepare(
      `INSERT INTO tasks (id, title, status, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?)`,
    );
    for (const status of validStatuses) {
      expect(() =>
        insert.run(randomUUID(), `task-${status}`, status, now, now),
      ).not.toThrow();
    }
  });

  it("tasks table rejects an invalid status value", () => {
    const now = new Date().toISOString();
    expect(() =>
      db
        .prepare(
          `INSERT INTO tasks (id, title, status, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?)`,
        )
        .run(randomUUID(), "bad-task", "INVALID_STATUS", now, now),
    ).toThrow();
  });

  it("external_id column has a UNIQUE constraint", () => {
    const now = new Date().toISOString();
    const extId = `ext-${randomUUID()}`;
    db.prepare(
      `INSERT INTO tasks (id, title, status, external_id, created_at, updated_at)
       VALUES (?, ?, 'backlog', ?, ?, ?)`,
    ).run(randomUUID(), "task-a", extId, now, now);
    expect(() =>
      db
        .prepare(
          `INSERT INTO tasks (id, title, status, external_id, created_at, updated_at)
           VALUES (?, ?, 'backlog', ?, ?, ?)`,
        )
        .run(randomUUID(), "task-b", extId, now, now),
    ).toThrow();
  });

  it("creates idx_tasks_status index", () => {
    const idx = db
      .prepare(
        "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_tasks_status'",
      )
      .get();
    expect(idx).toBeDefined();
  });

  it("creates idx_tasks_run_id index", () => {
    const idx = db
      .prepare(
        "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_tasks_run_id'",
      )
      .get();
    expect(idx).toBeDefined();
  });

  it("creates idx_tasks_created_at index", () => {
    const idx = db
      .prepare(
        "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_tasks_created_at'",
      )
      .get();
    expect(idx).toBeDefined();
  });
});

// ── DDL migration: task_dependencies table ─────────────────────────────

describe("ForemanStore DDL — task_dependencies table", () => {
  let store: ForemanStore;
  let tmpDir: string;
  let db: Database.Database;

  const now = new Date().toISOString();

  function insertTask(database: Database.Database, id: string, title: string): void {
    database
      .prepare(
        `INSERT INTO tasks (id, title, status, created_at, updated_at)
         VALUES (?, ?, 'backlog', ?, ?)`,
      )
      .run(id, title, now, now);
  }

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-deps-test-"));
    const dbPath = join(tmpDir, "test.db");
    store = new ForemanStore(dbPath);
    db = store.getDb();
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("creates the task_dependencies table", () => {
    const row = db
      .prepare(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='task_dependencies'",
      )
      .get();
    expect(row).toBeDefined();
  });

  it("task_dependencies table is idempotent across multiple store opens", () => {
    store.close();
    const dbPath = join(tmpDir, "test.db");
    const store2 = new ForemanStore(dbPath);
    const row = store2
      .getDb()
      .prepare(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='task_dependencies'",
      )
      .get();
    expect(row).toBeDefined();
    store2.close();
  });

  it("accepts 'blocks' dependency type", () => {
    const a = randomUUID();
    const b = randomUUID();
    insertTask(db, a, "task-a");
    insertTask(db, b, "task-b");
    expect(() =>
      db
        .prepare(
          `INSERT INTO task_dependencies (from_task_id, to_task_id, type)
           VALUES (?, ?, 'blocks')`,
        )
        .run(a, b),
    ).not.toThrow();
  });

  it("accepts 'parent-child' dependency type", () => {
    const parent = randomUUID();
    const child = randomUUID();
    insertTask(db, parent, "parent");
    insertTask(db, child, "child");
    expect(() =>
      db
        .prepare(
          `INSERT INTO task_dependencies (from_task_id, to_task_id, type)
           VALUES (?, ?, 'parent-child')`,
        )
        .run(parent, child),
    ).not.toThrow();
  });

  it("rejects an invalid dependency type", () => {
    const a = randomUUID();
    const b = randomUUID();
    insertTask(db, a, "task-a");
    insertTask(db, b, "task-b");
    expect(() =>
      db
        .prepare(
          `INSERT INTO task_dependencies (from_task_id, to_task_id, type)
           VALUES (?, ?, 'INVALID')`,
        )
        .run(a, b),
    ).toThrow();
  });

  it("cascades deletes from tasks to task_dependencies", () => {
    const a = randomUUID();
    const b = randomUUID();
    insertTask(db, a, "task-a");
    insertTask(db, b, "task-b");
    db
      .prepare(
        `INSERT INTO task_dependencies (from_task_id, to_task_id, type)
         VALUES (?, ?, 'blocks')`,
      )
      .run(a, b);
    // Delete task a — its dependency should cascade
    db.prepare("DELETE FROM tasks WHERE id = ?").run(a);
    const dep = db
      .prepare(
        "SELECT * FROM task_dependencies WHERE from_task_id = ? AND to_task_id = ?",
      )
      .get(a, b);
    expect(dep).toBeUndefined();
  });

  it("creates idx_task_dependencies_to_task index", () => {
    const idx = db
      .prepare(
        "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_task_dependencies_to_task'",
      )
      .get();
    expect(idx).toBeDefined();
  });

  it("enforces composite PRIMARY KEY on (from_task_id, to_task_id, type)", () => {
    const a = randomUUID();
    const b = randomUUID();
    insertTask(db, a, "task-a");
    insertTask(db, b, "task-b");
    db
      .prepare(
        `INSERT INTO task_dependencies (from_task_id, to_task_id, type)
         VALUES (?, ?, 'blocks')`,
      )
      .run(a, b);
    // Inserting the exact same row should fail
    expect(() =>
      db
        .prepare(
          `INSERT INTO task_dependencies (from_task_id, to_task_id, type)
           VALUES (?, ?, 'blocks')`,
        )
        .run(a, b),
    ).toThrow();
  });
});
