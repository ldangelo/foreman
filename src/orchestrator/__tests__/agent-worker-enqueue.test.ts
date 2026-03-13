import { describe, it, expect, beforeEach, afterEach } from "vitest";
import Database from "better-sqlite3";
import { MergeQueue } from "../merge-queue.js";
import { enqueueToMergeQueue } from "../agent-worker-enqueue.js";

// Minimal schema needed for tests
const TEST_SCHEMA = `
CREATE TABLE IF NOT EXISTS projects (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  path TEXT NOT NULL UNIQUE,
  status TEXT DEFAULT 'active',
  created_at TEXT,
  updated_at TEXT
);

CREATE TABLE IF NOT EXISTS runs (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  seed_id TEXT NOT NULL,
  agent_type TEXT NOT NULL,
  session_key TEXT,
  worktree_path TEXT,
  status TEXT DEFAULT 'pending',
  started_at TEXT,
  completed_at TEXT,
  created_at TEXT,
  progress TEXT DEFAULT NULL,
  FOREIGN KEY (project_id) REFERENCES projects(id)
);

CREATE TABLE IF NOT EXISTS merge_queue (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  branch_name TEXT NOT NULL,
  seed_id TEXT NOT NULL,
  run_id TEXT NOT NULL,
  agent_name TEXT,
  files_modified TEXT DEFAULT '[]',
  enqueued_at TEXT NOT NULL,
  started_at TEXT,
  completed_at TEXT,
  status TEXT DEFAULT 'pending'
    CHECK (status IN ('pending', 'merging', 'merged', 'conflict', 'failed')),
  resolved_tier INTEGER,
  error TEXT,
  FOREIGN KEY (run_id) REFERENCES runs(id)
);

CREATE INDEX IF NOT EXISTS idx_merge_queue_status ON merge_queue (status, enqueued_at);
`;

function createTestDb(): Database.Database {
  const db = new Database(":memory:");
  db.pragma("journal_mode = WAL");
  db.pragma("foreign_keys = ON");
  db.pragma("busy_timeout = 5000");
  db.exec(TEST_SCHEMA);
  return db;
}

function insertProject(db: Database.Database, id = "proj-1"): void {
  db.prepare(
    `INSERT INTO projects (id, name, path, status, created_at, updated_at)
     VALUES (?, 'Test', '/tmp/test', 'active', datetime('now'), datetime('now'))`
  ).run(id);
}

function insertRun(
  db: Database.Database,
  id: string,
  seedId: string,
  status = "completed",
  projectId = "proj-1"
): void {
  db.prepare(
    `INSERT INTO runs (id, project_id, seed_id, agent_type, status, created_at)
     VALUES (?, ?, ?, 'worker', ?, datetime('now'))`
  ).run(id, projectId, seedId, status);
}

describe("enqueueToMergeQueue", () => {
  let db: Database.Database;

  beforeEach(() => {
    db = createTestDb();
    insertProject(db);
    insertRun(db, "run-1", "seed-1");
  });

  afterEach(() => {
    db.close();
  });

  it("enqueues branch to merge queue after successful push with files_modified populated", () => {
    const result = enqueueToMergeQueue({
      db,
      seedId: "seed-1",
      runId: "run-1",
      worktreePath: "/tmp/test-worktree",
      getFilesModified: () => ["src/foo.ts", "src/bar.ts", "test/foo.test.ts"],
    });

    expect(result.success).toBe(true);
    expect(result.entry).toBeDefined();
    expect(result.entry!.branch_name).toBe("foreman/seed-1");
    expect(result.entry!.seed_id).toBe("seed-1");
    expect(result.entry!.run_id).toBe("run-1");
    expect(result.entry!.agent_name).toBe("pipeline");
    expect(result.entry!.files_modified).toEqual(["src/foo.ts", "src/bar.ts", "test/foo.test.ts"]);
    expect(result.entry!.status).toBe("pending");

    // Verify it is actually in the database
    const queue = new MergeQueue(db);
    const entries = queue.list("pending");
    expect(entries).toHaveLength(1);
    expect(entries[0].branch_name).toBe("foreman/seed-1");
  });

  it("gracefully handles enqueue errors without throwing", () => {
    // Close the db to force an error when enqueue tries to use it
    const badDb = createTestDb();
    insertProject(badDb);
    insertRun(badDb, "run-bad", "seed-bad");
    badDb.close();

    const result = enqueueToMergeQueue({
      db: badDb,
      seedId: "seed-bad",
      runId: "run-bad",
      worktreePath: "/tmp/test-worktree",
      getFilesModified: () => [],
    });

    expect(result.success).toBe(false);
    expect(result.error).toBeDefined();
    expect(result.error!.length).toBeGreaterThan(0);
    expect(result.entry).toBeUndefined();
  });

  it("extracts files_modified correctly from getFilesModified callback", () => {
    // Simulate git diff --name-only output parsing
    const gitDiffOutput = "src/lib/store.ts\nsrc/orchestrator/agent-worker.ts\npackage.json\n";
    const files = gitDiffOutput.trim().split("\n").filter(Boolean);

    const result = enqueueToMergeQueue({
      db,
      seedId: "seed-1",
      runId: "run-1",
      worktreePath: "/tmp/test-worktree",
      getFilesModified: () => files,
    });

    expect(result.success).toBe(true);
    expect(result.entry!.files_modified).toEqual([
      "src/lib/store.ts",
      "src/orchestrator/agent-worker.ts",
      "package.json",
    ]);
  });

  it("handles empty git diff output (no files modified)", () => {
    const result = enqueueToMergeQueue({
      db,
      seedId: "seed-1",
      runId: "run-1",
      worktreePath: "/tmp/test-worktree",
      getFilesModified: () => [],
    });

    expect(result.success).toBe(true);
    expect(result.entry!.files_modified).toEqual([]);
  });

  it("handles getFilesModified throwing an error gracefully", () => {
    const result = enqueueToMergeQueue({
      db,
      seedId: "seed-1",
      runId: "run-1",
      worktreePath: "/tmp/test-worktree",
      getFilesModified: () => { throw new Error("git diff failed"); },
    });

    // Should still enqueue with empty files list, not fail entirely
    expect(result.success).toBe(true);
    expect(result.entry!.files_modified).toEqual([]);
  });

  it("is idempotent: calling twice returns the same entry", () => {
    const opts = {
      db,
      seedId: "seed-1",
      runId: "run-1",
      worktreePath: "/tmp/test-worktree",
      getFilesModified: () => ["src/foo.ts"],
    };

    const first = enqueueToMergeQueue(opts);
    const second = enqueueToMergeQueue(opts);

    expect(first.success).toBe(true);
    expect(second.success).toBe(true);
    expect(first.entry!.id).toBe(second.entry!.id);

    // Verify only one entry in the queue
    const queue = new MergeQueue(db);
    expect(queue.list()).toHaveLength(1);
  });
});
