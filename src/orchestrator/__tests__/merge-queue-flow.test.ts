import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import Database from "better-sqlite3";
import { MergeQueue } from "../merge-queue.js";

const SCHEMA = `
CREATE TABLE IF NOT EXISTS projects (id TEXT PRIMARY KEY, name TEXT, path TEXT UNIQUE, status TEXT, created_at TEXT, updated_at TEXT);
CREATE TABLE IF NOT EXISTS runs (id TEXT PRIMARY KEY, project_id TEXT, seed_id TEXT, agent_type TEXT, status TEXT DEFAULT 'pending', created_at TEXT, FOREIGN KEY (project_id) REFERENCES projects(id));
CREATE TABLE IF NOT EXISTS merge_queue (id INTEGER PRIMARY KEY AUTOINCREMENT, branch_name TEXT NOT NULL, seed_id TEXT NOT NULL, run_id TEXT NOT NULL, agent_name TEXT, files_modified TEXT DEFAULT '[]', enqueued_at TEXT NOT NULL, started_at TEXT, completed_at TEXT, status TEXT DEFAULT 'pending' CHECK (status IN ('pending','merging','merged','conflict','failed')), resolved_tier INTEGER, error TEXT, FOREIGN KEY (run_id) REFERENCES runs(id));
CREATE INDEX IF NOT EXISTS idx_merge_queue_status ON merge_queue (status, enqueued_at);
`;

function mkDb(): Database.Database {
  const db = new Database(":memory:");
  db.pragma("journal_mode = WAL");
  db.pragma("foreign_keys = ON");
  db.exec(SCHEMA);
  db.prepare("INSERT INTO projects VALUES ('p1','T','/tmp','active',datetime('now'),datetime('now'))").run();
  return db;
}

function addRun(db: Database.Database, id: string, seedId: string, status = "completed"): void {
  db.prepare("INSERT INTO runs (id,project_id,seed_id,agent_type,status,created_at) VALUES (?,'p1',?,'w',?,datetime('now'))").run(id, seedId, status);
}

const mockGit = () => vi.fn().mockResolvedValue({ stdout: "ok\n", stderr: "" });

// ── Test 1: Reconcile ───────────────────────────────────────────────

describe("Reconcile detects missing entries", () => {
  let db: Database.Database;
  let mq: MergeQueue;
  beforeEach(() => { db = mkDb(); mq = new MergeQueue(db); });
  afterEach(() => { db.close(); });

  it("enqueues completed runs not already queued", async () => {
    addRun(db, "r1", "s1", "completed");
    addRun(db, "r2", "s2", "completed");
    addRun(db, "r3", "s3", "running");
    const r = await mq.reconcile(db, "/tmp", mockGit());
    expect(r.enqueued).toBe(2);
    expect(mq.list()).toHaveLength(2);
  });

  it("skips already-queued runs", async () => {
    addRun(db, "r1", "s1", "completed");
    mq.enqueue({ branchName: "foreman/s1", seedId: "s1", runId: "r1" });
    const r = await mq.reconcile(db, "/tmp", mockGit());
    expect(r.skipped).toBe(1);
    expect(r.enqueued).toBe(0);
  });
});

// ── Test 2: FIFO Dequeue ────────────────────────────────────────────

describe("Dequeue processes in FIFO order", () => {
  let db: Database.Database;
  let mq: MergeQueue;
  beforeEach(() => {
    db = mkDb();
    addRun(db, "r1", "s1"); addRun(db, "r2", "s2"); addRun(db, "r3", "s3");
    mq = new MergeQueue(db);
  });
  afterEach(() => { db.close(); });

  it("returns entries in enqueue order", () => {
    mq.enqueue({ branchName: "foreman/s3", seedId: "s3", runId: "r3" });
    mq.enqueue({ branchName: "foreman/s1", seedId: "s1", runId: "r1" });
    mq.enqueue({ branchName: "foreman/s2", seedId: "s2", runId: "r2" });
    expect(mq.dequeue()!.seed_id).toBe("s3");
    expect(mq.dequeue()!.seed_id).toBe("s1");
    expect(mq.dequeue()!.seed_id).toBe("s2");
    expect(mq.dequeue()).toBeNull();
  });

  it("skips merging entries", () => {
    mq.enqueue({ branchName: "foreman/s1", seedId: "s1", runId: "r1" });
    mq.enqueue({ branchName: "foreman/s2", seedId: "s2", runId: "r2" });
    expect(mq.dequeue()!.seed_id).toBe("s1");
    expect(mq.dequeue()!.seed_id).toBe("s2");
    expect(mq.dequeue()).toBeNull();
  });
});

// ── Test 3: Status Transitions ──────────────────────────────────────

describe("Status transitions are correct", () => {
  let db: Database.Database;
  let mq: MergeQueue;
  beforeEach(() => {
    db = mkDb();
    addRun(db, "r1", "s1"); addRun(db, "r2", "s2"); addRun(db, "r3", "s3");
    mq = new MergeQueue(db);
  });
  afterEach(() => { db.close(); });

  it("pending -> merging -> merged", () => {
    mq.enqueue({ branchName: "foreman/s1", seedId: "s1", runId: "r1" });
    expect(mq.list("pending")).toHaveLength(1);
    const e = mq.dequeue()!;
    expect(e.status).toBe("merging");
    expect(e.started_at).toBeTruthy();
    mq.updateStatus(e.id, "merged", { completedAt: new Date().toISOString() });
    expect(mq.list("merged")).toHaveLength(1);
    expect(mq.list("merged")[0].completed_at).toBeTruthy();
  });

  it("pending -> merging -> conflict", () => {
    mq.enqueue({ branchName: "foreman/s2", seedId: "s2", runId: "r2" });
    const e = mq.dequeue()!;
    mq.updateStatus(e.id, "conflict", { error: "conflicts in src/foo.ts" });
    expect(mq.list("conflict")).toHaveLength(1);
    expect(mq.list("conflict")[0].error).toBe("conflicts in src/foo.ts");
  });

  it("pending -> merging -> failed", () => {
    mq.enqueue({ branchName: "foreman/s3", seedId: "s3", runId: "r3" });
    const e = mq.dequeue()!;
    mq.updateStatus(e.id, "failed", { error: "test failures" });
    expect(mq.list("failed")).toHaveLength(1);
    expect(mq.list("failed")[0].error).toBe("test failures");
  });

  it("non-pending entries are not dequeued", () => {
    mq.enqueue({ branchName: "foreman/s1", seedId: "s1", runId: "r1" });
    mq.enqueue({ branchName: "foreman/s2", seedId: "s2", runId: "r2" });
    mq.enqueue({ branchName: "foreman/s3", seedId: "s3", runId: "r3" });
    const a = mq.dequeue()!; mq.updateStatus(a.id, "merged");
    const b = mq.dequeue()!; mq.updateStatus(b.id, "failed", { error: "x" });
    expect(mq.dequeue()!.seed_id).toBe("s3");
    expect(mq.dequeue()).toBeNull();
  });
});

// ── Test 4: CLI Integration ─────────────────────────────────────────

describe("Queue integration with merge CLI flow", () => {
  let db: Database.Database;
  let mq: MergeQueue;
  beforeEach(() => { db = mkDb(); mq = new MergeQueue(db); });
  afterEach(() => { db.close(); });

  it("full flow: reconcile -> dequeue loop -> status updates", async () => {
    addRun(db, "r1", "s1", "completed");
    addRun(db, "r2", "s2", "completed");
    addRun(db, "r3", "s3", "completed");

    const r = await mq.reconcile(db, "/tmp", mockGit());
    expect(r.enqueued).toBe(3);

    const results: string[] = [];
    let e = mq.dequeue();
    while (e) {
      if (e.seed_id === "s1") mq.updateStatus(e.id, "merged", { completedAt: new Date().toISOString() });
      else if (e.seed_id === "s2") mq.updateStatus(e.id, "conflict", { error: "conflicts" });
      else mq.updateStatus(e.id, "failed", { error: "tests" });
      results.push(e.seed_id);
      e = mq.dequeue();
    }

    expect(results).toHaveLength(3);
    expect(mq.list("merged")).toHaveLength(1);
    expect(mq.list("conflict")).toHaveLength(1);
    expect(mq.list("failed")).toHaveLength(1);
    expect(mq.list("pending")).toHaveLength(0);
  });

  it("list shows files_modified and enqueued_at", () => {
    addRun(db, "r1", "s1");
    addRun(db, "r2", "s2");
    mq.enqueue({ branchName: "foreman/s1", seedId: "s1", runId: "r1", filesModified: ["a.ts", "b.ts"] });
    mq.enqueue({ branchName: "foreman/s2", seedId: "s2", runId: "r2", filesModified: ["c.ts"] });

    const entries = mq.list("pending");
    expect(entries).toHaveLength(2);
    expect(entries.every((e) => e.enqueued_at && e.branch_name && Array.isArray(e.files_modified))).toBe(true);
    expect(entries.find((e) => e.seed_id === "s1")!.files_modified).toHaveLength(2);
  });

  it("list shows all statuses without filter", () => {
    addRun(db, "r1", "s1"); addRun(db, "r2", "s2"); addRun(db, "r3", "s3");
    mq.enqueue({ branchName: "foreman/s1", seedId: "s1", runId: "r1" });
    mq.enqueue({ branchName: "foreman/s2", seedId: "s2", runId: "r2" });
    mq.enqueue({ branchName: "foreman/s3", seedId: "s3", runId: "r3" });
    mq.updateStatus(mq.dequeue()!.id, "merged");
    mq.updateStatus(mq.dequeue()!.id, "conflict", { error: "x" });

    const all = mq.list();
    expect(all).toHaveLength(3);
    expect(new Set(all.map((e) => e.status))).toEqual(new Set(["merged", "conflict", "pending"]));
  });

  it("seed filter: only process matching entry from pending list", () => {
    addRun(db, "r1", "s1"); addRun(db, "r2", "s2");
    mq.enqueue({ branchName: "foreman/s1", seedId: "s1", runId: "r1" });
    mq.enqueue({ branchName: "foreman/s2", seedId: "s2", runId: "r2" });

    // For --seed filter, find matching entry in pending list, then dequeue+process
    const target = "s2";
    const pending = mq.list("pending");
    const match = pending.find((e) => e.seed_id === target);
    expect(match).toBeDefined();

    // Dequeue will return the first pending entry (s1), not the target.
    // The merge command should dequeue and process only until it finds the target,
    // skipping non-matching entries by marking them back to pending after the loop.
    const merged: string[] = [];
    const skipped: number[] = [];
    let e = mq.dequeue();
    while (e) {
      if (e.seed_id === target) {
        mq.updateStatus(e.id, "merged", { completedAt: new Date().toISOString() });
        merged.push(e.seed_id);
        break; // stop after finding target
      } else {
        skipped.push(e.id);
      }
      e = mq.dequeue();
    }

    // Reset skipped entries back to pending
    for (const id of skipped) {
      mq.updateStatus(id, "pending");
    }

    expect(merged).toEqual(["s2"]);
    expect(mq.list("pending")).toHaveLength(1);
    expect(mq.list("pending")[0].seed_id).toBe("s1");
  });
});
