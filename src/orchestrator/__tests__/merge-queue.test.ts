import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import Database from "better-sqlite3";
import { MergeQueue } from "../merge-queue.js";
import type { MergeQueueEntry, MergeQueueStatus } from "../merge-queue.js";

vi.mock("../../lib/git.js", () => ({
  detectDefaultBranch: vi.fn().mockResolvedValue("main"),
}));

// Minimal schema needed for tests (merge_queue + runs for FK)
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
  retry_count INTEGER DEFAULT 0,
  last_attempted_at TEXT DEFAULT NULL,
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

describe("MergeQueue", () => {
  let db: Database.Database;
  let queue: MergeQueue;

  beforeEach(() => {
    db = createTestDb();
    insertProject(db);
    insertRun(db, "run-1", "seed-1");
    insertRun(db, "run-2", "seed-2");
    insertRun(db, "run-3", "seed-3");
    queue = new MergeQueue(db);
  });

  afterEach(() => {
    db.close();
  });

  // ── Enqueue and retrieve ────────────────────────────────────────────

  describe("enqueue", () => {
    it("inserts a new entry and returns it with an id", () => {
      const entry = queue.enqueue({
        branchName: "foreman/seed-1",
        seedId: "seed-1",
        runId: "run-1",
        agentName: "developer",
        filesModified: ["src/foo.ts", "src/bar.ts"],
      });

      expect(entry.id).toBeGreaterThan(0);
      expect(entry.branch_name).toBe("foreman/seed-1");
      expect(entry.seed_id).toBe("seed-1");
      expect(entry.run_id).toBe("run-1");
      expect(entry.agent_name).toBe("developer");
      expect(entry.files_modified).toEqual(["src/foo.ts", "src/bar.ts"]);
      expect(entry.status).toBe("pending");
      expect(entry.enqueued_at).toBeTruthy();
      expect(entry.started_at).toBeNull();
      expect(entry.completed_at).toBeNull();
      expect(entry.resolved_tier).toBeNull();
      expect(entry.error).toBeNull();
    });

    it("defaults filesModified to empty array", () => {
      const entry = queue.enqueue({
        branchName: "foreman/seed-1",
        seedId: "seed-1",
        runId: "run-1",
      });

      expect(entry.files_modified).toEqual([]);
    });

    it("is idempotent: same branch+run returns existing entry", () => {
      const first = queue.enqueue({
        branchName: "foreman/seed-1",
        seedId: "seed-1",
        runId: "run-1",
        agentName: "developer",
      });

      const second = queue.enqueue({
        branchName: "foreman/seed-1",
        seedId: "seed-1",
        runId: "run-1",
        agentName: "different-agent",
      });

      expect(second.id).toBe(first.id);
      // Should return the original, not update it
      expect(second.agent_name).toBe("developer");
    });
  });

  // ── Dequeue atomicity ──────────────────────────────────────────────

  describe("dequeue", () => {
    it("returns the oldest pending entry and marks it as merging", () => {
      queue.enqueue({ branchName: "foreman/seed-1", seedId: "seed-1", runId: "run-1" });
      queue.enqueue({ branchName: "foreman/seed-2", seedId: "seed-2", runId: "run-2" });

      const entry = queue.dequeue();
      expect(entry).not.toBeNull();
      expect(entry!.branch_name).toBe("foreman/seed-1");
      expect(entry!.status).toBe("merging");
      expect(entry!.started_at).toBeTruthy();
    });

    it("returns null when no pending entries", () => {
      expect(queue.dequeue()).toBeNull();
    });

    it("does not return already-dequeued entries", () => {
      queue.enqueue({ branchName: "foreman/seed-1", seedId: "seed-1", runId: "run-1" });

      const first = queue.dequeue();
      const second = queue.dequeue();

      expect(first).not.toBeNull();
      expect(second).toBeNull();
    });

    it("dequeues in FIFO order", () => {
      queue.enqueue({ branchName: "foreman/seed-1", seedId: "seed-1", runId: "run-1" });
      queue.enqueue({ branchName: "foreman/seed-2", seedId: "seed-2", runId: "run-2" });
      queue.enqueue({ branchName: "foreman/seed-3", seedId: "seed-3", runId: "run-3" });

      expect(queue.dequeue()!.seed_id).toBe("seed-1");
      expect(queue.dequeue()!.seed_id).toBe("seed-2");
      expect(queue.dequeue()!.seed_id).toBe("seed-3");
      expect(queue.dequeue()).toBeNull();
    });
  });

  // ── Peek ───────────────────────────────────────────────────────────

  describe("peek", () => {
    it("returns the next pending entry without modifying it", () => {
      queue.enqueue({ branchName: "foreman/seed-1", seedId: "seed-1", runId: "run-1" });

      const peeked = queue.peek();
      expect(peeked).not.toBeNull();
      expect(peeked!.status).toBe("pending");

      // Peek again — should still be there
      const peekedAgain = queue.peek();
      expect(peekedAgain).not.toBeNull();
      expect(peekedAgain!.id).toBe(peeked!.id);
    });

    it("returns null when no pending entries", () => {
      expect(queue.peek()).toBeNull();
    });
  });

  // ── List ───────────────────────────────────────────────────────────

  describe("list", () => {
    it("returns all entries when no status filter", () => {
      queue.enqueue({ branchName: "foreman/seed-1", seedId: "seed-1", runId: "run-1" });
      queue.enqueue({ branchName: "foreman/seed-2", seedId: "seed-2", runId: "run-2" });
      queue.dequeue(); // marks seed-1 as merging

      const all = queue.list();
      expect(all).toHaveLength(2);
    });

    it("filters by status", () => {
      queue.enqueue({ branchName: "foreman/seed-1", seedId: "seed-1", runId: "run-1" });
      queue.enqueue({ branchName: "foreman/seed-2", seedId: "seed-2", runId: "run-2" });
      queue.dequeue(); // marks seed-1 as merging

      const pending = queue.list("pending");
      expect(pending).toHaveLength(1);
      expect(pending[0].seed_id).toBe("seed-2");

      const merging = queue.list("merging");
      expect(merging).toHaveLength(1);
      expect(merging[0].seed_id).toBe("seed-1");
    });
  });

  // ── UpdateStatus ───────────────────────────────────────────────────

  describe("updateStatus", () => {
    it("updates status of an entry", () => {
      const entry = queue.enqueue({ branchName: "foreman/seed-1", seedId: "seed-1", runId: "run-1" });
      queue.updateStatus(entry.id, "merged", { completedAt: "2026-01-01T00:00:00Z" });

      const merged = queue.list("merged");
      expect(merged).toHaveLength(1);
      expect(merged[0].completed_at).toBe("2026-01-01T00:00:00Z");
    });

    it("updates error and resolved_tier", () => {
      const entry = queue.enqueue({ branchName: "foreman/seed-1", seedId: "seed-1", runId: "run-1" });
      queue.updateStatus(entry.id, "conflict", {
        error: "CONFLICT in src/foo.ts",
        resolvedTier: 2,
      });

      const conflicts = queue.list("conflict");
      expect(conflicts).toHaveLength(1);
      expect(conflicts[0].error).toBe("CONFLICT in src/foo.ts");
      expect(conflicts[0].resolved_tier).toBe(2);
    });

    it("updates status without extras", () => {
      const entry = queue.enqueue({ branchName: "foreman/seed-1", seedId: "seed-1", runId: "run-1" });
      queue.updateStatus(entry.id, "failed");

      const failed = queue.list("failed");
      expect(failed).toHaveLength(1);
    });
  });

  // ── Remove ─────────────────────────────────────────────────────────

  describe("remove", () => {
    it("deletes an entry", () => {
      const entry = queue.enqueue({ branchName: "foreman/seed-1", seedId: "seed-1", runId: "run-1" });
      queue.remove(entry.id);

      expect(queue.list()).toHaveLength(0);
    });

    it("does nothing for non-existent id", () => {
      // Should not throw
      queue.remove(9999);
      expect(queue.list()).toHaveLength(0);
    });
  });

  // ── files_modified JSON parsing ────────────────────────────────────

  describe("files_modified serialization", () => {
    it("round-trips file lists through JSON", () => {
      const files = ["src/a.ts", "src/b.ts", "test/c.test.ts"];
      const entry = queue.enqueue({
        branchName: "foreman/seed-1",
        seedId: "seed-1",
        runId: "run-1",
        filesModified: files,
      });

      expect(entry.files_modified).toEqual(files);

      // Also verify via list
      const listed = queue.list();
      expect(listed[0].files_modified).toEqual(files);
    });
  });

  // ── resetForRetry ──────────────────────────────────────────────────
  describe("resetForRetry", () => {
    it("resets a failed entry back to pending", () => {
      const entry = queue.enqueue({ branchName: "foreman/seed-1", seedId: "seed-1", runId: "run-1" });
      queue.updateStatus(entry.id, "failed", { error: "some error" });

      const result = queue.resetForRetry("seed-1");
      expect(result).toBe(true);

      const pending = queue.list("pending");
      expect(pending).toHaveLength(1);
      expect(pending[0].error).toBeNull();
      expect(pending[0].last_attempted_at).not.toBeNull();
    });

    it("resets a conflict entry back to pending", () => {
      const entry = queue.enqueue({ branchName: "foreman/seed-1", seedId: "seed-1", runId: "run-1" });
      queue.updateStatus(entry.id, "conflict", { error: "Code conflicts" });

      const result = queue.resetForRetry("seed-1");
      expect(result).toBe(true);

      const pending = queue.list("pending");
      expect(pending).toHaveLength(1);
    });

    it("returns false when no retryable entry exists for seed", () => {
      const entry = queue.enqueue({ branchName: "foreman/seed-1", seedId: "seed-1", runId: "run-1" });
      queue.updateStatus(entry.id, "merged", { completedAt: new Date().toISOString() });

      const result = queue.resetForRetry("seed-1");
      expect(result).toBe(false);
    });

    it("returns false for nonexistent seed", () => {
      expect(queue.resetForRetry("nonexistent")).toBe(false);
    });
  });

  // ── reEnqueue and retry logic ──────────────────────────────────────
  describe("reEnqueue", () => {
    it("re-enqueues a failed entry and increments retry_count", () => {
      const entry = queue.enqueue({ branchName: "foreman/seed-1", seedId: "seed-1", runId: "run-1" });
      queue.updateStatus(entry.id, "failed", { error: "Test failures" });

      const result = queue.reEnqueue(entry.id);
      expect(result).toBe(true);

      const pending = queue.list("pending");
      expect(pending).toHaveLength(1);
      expect(pending[0].retry_count).toBe(1);
      expect(pending[0].error).toBeNull();
      expect(pending[0].last_attempted_at).toBeTruthy();
    });

    it("re-enqueues a conflict entry", () => {
      const entry = queue.enqueue({ branchName: "foreman/seed-1", seedId: "seed-1", runId: "run-1" });
      queue.updateStatus(entry.id, "conflict", { error: "Code conflicts" });

      const result = queue.reEnqueue(entry.id);
      expect(result).toBe(true);

      const pending = queue.list("pending");
      expect(pending[0].retry_count).toBe(1);
    });

    it("returns false for entries at max retry limit", () => {
      const entry = queue.enqueue({ branchName: "foreman/seed-1", seedId: "seed-1", runId: "run-1" });
      queue.updateStatus(entry.id, "failed", { error: "err" });

      // Exhaust retries
      queue.reEnqueue(entry.id); // retry_count → 1
      queue.updateStatus(entry.id, "failed", { error: "err" });
      queue.reEnqueue(entry.id); // retry_count → 2
      queue.updateStatus(entry.id, "failed", { error: "err" });
      queue.reEnqueue(entry.id); // retry_count → 3 (= maxRetries)
      queue.updateStatus(entry.id, "failed", { error: "err" });

      const result = queue.reEnqueue(entry.id); // should fail: retry_count >= maxRetries
      expect(result).toBe(false);
      expect(queue.list("failed")).toHaveLength(1);
    });

    it("returns false for non-failed/conflict entries", () => {
      const entry = queue.enqueue({ branchName: "foreman/seed-1", seedId: "seed-1", runId: "run-1" });
      // status is 'pending'
      const result = queue.reEnqueue(entry.id);
      expect(result).toBe(false);
    });

    it("returns false for nonexistent id", () => {
      expect(queue.reEnqueue(9999)).toBe(false);
    });
  });

  // ── shouldRetry and getRetryableEntries ────────────────────────────
  describe("shouldRetry", () => {
    it("returns true for a fresh failed entry with no retry history", () => {
      const entry = queue.enqueue({ branchName: "foreman/seed-1", seedId: "seed-1", runId: "run-1" });
      queue.updateStatus(entry.id, "failed", { error: "err" });
      const failed = queue.list("failed");

      expect(queue.shouldRetry(failed[0])).toBe(true);
    });

    it("returns false when retry_count >= maxRetries", () => {
      const entry = queue.enqueue({ branchName: "foreman/seed-1", seedId: "seed-1", runId: "run-1" });
      queue.updateStatus(entry.id, "failed", { error: "err" });
      // Manually simulate maxed out retries
      queue.reEnqueue(entry.id);
      queue.updateStatus(entry.id, "failed", { error: "err" });
      queue.reEnqueue(entry.id);
      queue.updateStatus(entry.id, "failed", { error: "err" });
      queue.reEnqueue(entry.id);
      queue.updateStatus(entry.id, "failed", { error: "err" });

      const failed = queue.list("failed");
      expect(queue.shouldRetry(failed[0])).toBe(false);
    });
  });

  describe("getRetryableEntries", () => {
    it("returns failed/conflict entries eligible for retry", () => {
      const e1 = queue.enqueue({ branchName: "foreman/seed-1", seedId: "seed-1", runId: "run-1" });
      const e2 = queue.enqueue({ branchName: "foreman/seed-2", seedId: "seed-2", runId: "run-2" });
      queue.updateStatus(e1.id, "failed", { error: "err" });
      queue.updateStatus(e2.id, "conflict", { error: "conflict" });

      const retryable = queue.getRetryableEntries();
      expect(retryable).toHaveLength(2);
      expect(retryable.map(e => e.seed_id)).toContain("seed-1");
      expect(retryable.map(e => e.seed_id)).toContain("seed-2");
    });

    it("excludes entries that have exhausted retry limit", () => {
      const entry = queue.enqueue({ branchName: "foreman/seed-1", seedId: "seed-1", runId: "run-1" });
      queue.updateStatus(entry.id, "failed", { error: "err" });
      queue.reEnqueue(entry.id);
      queue.updateStatus(entry.id, "failed", { error: "err" });
      queue.reEnqueue(entry.id);
      queue.updateStatus(entry.id, "failed", { error: "err" });
      queue.reEnqueue(entry.id);
      queue.updateStatus(entry.id, "failed", { error: "err" });

      const retryable = queue.getRetryableEntries();
      expect(retryable).toHaveLength(0);
    });

    it("returns empty array when no failed/conflict entries", () => {
      queue.enqueue({ branchName: "foreman/seed-1", seedId: "seed-1", runId: "run-1" });
      expect(queue.getRetryableEntries()).toHaveLength(0);
    });
  });
});

// ── Reconcile ────────────────────────────────────────────────────────

describe("MergeQueue.reconcile", () => {
  let db: Database.Database;
  let queue: MergeQueue;

  beforeEach(() => {
    db = createTestDb();
    insertProject(db);
    queue = new MergeQueue(db);
  });

  afterEach(() => {
    db.close();
  });

  it("enqueues completed runs not already in merge_queue", async () => {
    // Insert completed runs
    insertRun(db, "run-1", "seed-1", "completed");
    insertRun(db, "run-2", "seed-2", "completed");

    // Mock git commands via injected execFile
    const mockExecFileAsync = vi.fn();
    // rev-parse succeeds for both branches
    mockExecFileAsync.mockImplementation((_cmd: string, args: string[]) => {
      if (args[0] === "rev-parse") {
        return Promise.resolve({ stdout: "abc123\n", stderr: "" });
      }
      if (args[0] === "diff") {
        return Promise.resolve({ stdout: "src/foo.ts\nsrc/bar.ts\n", stderr: "" });
      }
      return Promise.resolve({ stdout: "", stderr: "" });
    });

    const result = await queue.reconcile(db, "/tmp/repo", mockExecFileAsync);

    expect(result.enqueued).toBe(2);
    expect(result.skipped).toBe(0);
    expect(result.invalidBranch).toBe(0);

    const entries = queue.list();
    expect(entries).toHaveLength(2);
  });

  it("skips runs already in merge_queue", async () => {
    insertRun(db, "run-1", "seed-1", "completed");

    // Pre-enqueue run-1
    queue.enqueue({ branchName: "foreman/seed-1", seedId: "seed-1", runId: "run-1" });

    const mockExecFileAsync = vi.fn();
    const result = await queue.reconcile(db, "/tmp/repo", mockExecFileAsync);

    expect(result.enqueued).toBe(0);
    expect(result.skipped).toBe(1);
    expect(result.invalidBranch).toBe(0);
    // git should not have been called since the run was already queued
    expect(mockExecFileAsync).not.toHaveBeenCalled();
  });

  it("counts invalid branches when rev-parse fails", async () => {
    insertRun(db, "run-1", "seed-1", "completed");

    const mockExecFileAsync = vi.fn();
    mockExecFileAsync.mockImplementation((_cmd: string, args: string[]) => {
      if (args[0] === "rev-parse") {
        return Promise.reject(new Error("fatal: not a valid ref"));
      }
      return Promise.resolve({ stdout: "", stderr: "" });
    });

    const result = await queue.reconcile(db, "/tmp/repo", mockExecFileAsync);

    expect(result.enqueued).toBe(0);
    expect(result.skipped).toBe(0);
    expect(result.invalidBranch).toBe(1);
  });

  it("handles empty diff output for files_modified", async () => {
    insertRun(db, "run-1", "seed-1", "completed");

    const mockExecFileAsync = vi.fn();
    mockExecFileAsync.mockImplementation((_cmd: string, args: string[]) => {
      if (args[0] === "rev-parse") {
        return Promise.resolve({ stdout: "abc123\n", stderr: "" });
      }
      if (args[0] === "diff") {
        return Promise.resolve({ stdout: "", stderr: "" });
      }
      return Promise.resolve({ stdout: "", stderr: "" });
    });

    const result = await queue.reconcile(db, "/tmp/repo", mockExecFileAsync);

    expect(result.enqueued).toBe(1);
    const entries = queue.list();
    expect(entries[0].files_modified).toEqual([]);
  });

  it("does not enqueue non-completed runs without a pushed remote branch", async () => {
    insertRun(db, "run-1", "seed-1", "running");
    insertRun(db, "run-2", "seed-2", "failed");

    // Secondary pass will check for remote branches; reject all to simulate no push
    const mockExecFileAsync = vi.fn().mockImplementation((_cmd: string, args: string[]) => {
      if (args[0] === "rev-parse") {
        return Promise.reject(new Error("fatal: not a valid ref"));
      }
      return Promise.resolve({ stdout: "", stderr: "" });
    });
    const result = await queue.reconcile(db, "/tmp/repo", mockExecFileAsync);

    expect(result.enqueued).toBe(0);
    expect(result.skipped).toBe(0);
    expect(result.invalidBranch).toBe(0);
    // Secondary pass checks the remote branch only for "running" runs — not "failed".
    // Assert on the specific args (not just call count) so that adding a preliminary
    // step (e.g. a git fetch) before rev-parse does not break this test.
    expect(mockExecFileAsync).toHaveBeenCalledTimes(1);
    expect(mockExecFileAsync).toHaveBeenCalledWith(
      "git",
      ["rev-parse", "--verify", "refs/remotes/origin/foreman/seed-1"],
      { cwd: "/tmp/repo" }
    );
  });

  it("recovers a running run whose branch was pushed before process crashed", async () => {
    // Insert run with an explicit UTC ISO timestamp so timezone parsing is unambiguous.
    // The run was "created" at 2026-01-01T00:00:00Z.
    db.prepare(
      `INSERT INTO runs (id, project_id, seed_id, agent_type, status, created_at)
       VALUES ('run-1', 'proj-1', 'seed-1', 'worker', 'running', '2026-01-01T00:00:00.000Z')`
    ).run();

    // Commit epoch: 2026-01-02 (after the run was created) — should trigger recovery.
    // 2026-01-02T00:00:00Z in Unix seconds:
    const commitEpoch = Math.floor(new Date("2026-01-02T00:00:00.000Z").getTime() / 1000);

    const mockExecFileAsync = vi.fn().mockImplementation((_cmd: string, args: string[]) => {
      if (args[0] === "rev-parse" && args[2] === "refs/remotes/origin/foreman/seed-1") {
        // Remote branch exists — push succeeded before crash
        return Promise.resolve({ stdout: "abc123\n", stderr: "" });
      }
      if (args[0] === "log" && args.includes("--format=%ct")) {
        // Remote branch commit time is after run creation → not a stale ref → recover
        return Promise.resolve({ stdout: `${commitEpoch}\n`, stderr: "" });
      }
      if (args[0] === "diff") {
        return Promise.resolve({ stdout: "src/foo.ts\nsrc/bar.ts\n", stderr: "" });
      }
      return Promise.reject(new Error("unexpected git call"));
    });

    const result = await queue.reconcile(db, "/tmp/repo", mockExecFileAsync);

    expect(result.enqueued).toBe(1);
    expect(result.skipped).toBe(0);
    expect(result.invalidBranch).toBe(0);

    // Branch should be in merge queue
    const entries = queue.list("pending");
    expect(entries).toHaveLength(1);
    expect(entries[0].branch_name).toBe("foreman/seed-1");
    expect(entries[0].run_id).toBe("run-1");

    // Run status should be updated to completed
    const updatedRun = db.prepare("SELECT status FROM runs WHERE id = ?").get("run-1") as { status: string };
    expect(updatedRun.status).toBe("completed");
  });

  it("recovers a pending run whose branch was pushed before process crashed", async () => {
    db.prepare(
      `INSERT INTO runs (id, project_id, seed_id, agent_type, status, created_at)
       VALUES ('run-1', 'proj-1', 'seed-1', 'worker', 'pending', '2026-01-01T00:00:00.000Z')`
    ).run();

    // Commit 24 hours after run creation — definitely a legitimate recovery
    const commitEpoch = Math.floor(new Date("2026-01-02T00:00:00.000Z").getTime() / 1000);

    const mockExecFileAsync = vi.fn().mockImplementation((_cmd: string, args: string[]) => {
      if (args[0] === "rev-parse" && args[2] === "refs/remotes/origin/foreman/seed-1") {
        return Promise.resolve({ stdout: "abc123\n", stderr: "" });
      }
      if (args[0] === "log" && args.includes("--format=%ct")) {
        return Promise.resolve({ stdout: `${commitEpoch}\n`, stderr: "" });
      }
      if (args[0] === "diff") {
        return Promise.resolve({ stdout: "src/changed.ts\n", stderr: "" });
      }
      return Promise.reject(new Error("unexpected git call"));
    });

    const result = await queue.reconcile(db, "/tmp/repo", mockExecFileAsync);

    expect(result.enqueued).toBe(1);
    const entries = queue.list("pending");
    expect(entries[0].files_modified).toEqual(["src/changed.ts"]);

    const updatedRun = db.prepare("SELECT status FROM runs WHERE id = ?").get("run-1") as { status: string };
    expect(updatedRun.status).toBe("completed");
  });

  it("skips recovery when remote branch commit predates run creation (stale ref after foreman reset)", async () => {
    // Simulate the bd-yd8x bug:
    //   1. Old run pushed branch at T=past (remote ref exists with an old commit)
    //   2. foreman reset deleted local branch but left remote tracking ref
    //   3. New run created AFTER the old push
    //   → reconcile() secondary pass must NOT falsely mark new run as "completed"
    //
    // Run created at 2026-02-01T00:00:00Z (after the old push on 2026-01-01)
    db.prepare(
      `INSERT INTO runs (id, project_id, seed_id, agent_type, status, created_at)
       VALUES ('run-new', 'proj-1', 'seed-1', 'worker', 'pending', '2026-02-01T00:00:00.000Z')`
    ).run();

    // Remote branch was last committed on 2026-01-01 — BEFORE this run was created
    const staleCommitEpoch = Math.floor(new Date("2026-01-01T00:00:00.000Z").getTime() / 1000);

    const mockExecFileAsync = vi.fn().mockImplementation((_cmd: string, args: string[]) => {
      if (args[0] === "rev-parse" && args[2] === "refs/remotes/origin/foreman/seed-1") {
        // Stale remote ref still exists after foreman reset
        return Promise.resolve({ stdout: "abc123\n", stderr: "" });
      }
      if (args[0] === "log" && args.includes("--format=%ct")) {
        // Remote branch was last committed before this run was created — stale!
        return Promise.resolve({ stdout: `${staleCommitEpoch}\n`, stderr: "" });
      }
      return Promise.reject(new Error("unexpected git call"));
    });

    const result = await queue.reconcile(db, "/tmp/repo", mockExecFileAsync);

    // Should NOT be enqueued — stale remote ref from previous run
    expect(result.enqueued).toBe(0);
    expect(queue.list()).toHaveLength(0);

    // Run status must remain "pending" — it was NOT falsely marked "completed"
    const run = db.prepare("SELECT status FROM runs WHERE id = ?").get("run-new") as { status: string };
    expect(run.status).toBe("pending");
  });

  it("does not recover a running run already in merge_queue", async () => {
    insertRun(db, "run-1", "seed-1", "running");
    queue.enqueue({ branchName: "foreman/seed-1", seedId: "seed-1", runId: "run-1" });

    const mockExecFileAsync = vi.fn().mockImplementation((_cmd: string, args: string[]) => {
      if (args[0] === "rev-parse") {
        return Promise.resolve({ stdout: "abc123\n", stderr: "" });
      }
      return Promise.resolve({ stdout: "", stderr: "" });
    });

    const result = await queue.reconcile(db, "/tmp/repo", mockExecFileAsync);

    // Already in queue — skipped in secondary pass
    expect(result.enqueued).toBe(0);
    expect(queue.list()).toHaveLength(1);
  });

  it("recovers completed run and running run with pushed branch in single reconcile", async () => {
    // Use explicit UTC timestamps to avoid timezone parsing ambiguity.
    // Both runs "created" well before the commit epoch below.
    db.prepare(
      `INSERT INTO runs (id, project_id, seed_id, agent_type, status, created_at)
       VALUES ('run-1', 'proj-1', 'seed-1', 'worker', 'completed', '2026-01-01T00:00:00.000Z')`
    ).run();
    db.prepare(
      `INSERT INTO runs (id, project_id, seed_id, agent_type, status, created_at)
       VALUES ('run-2', 'proj-1', 'seed-2', 'worker', 'running', '2026-01-01T00:00:00.000Z')`
    ).run();

    // Commit epoch after both runs were created — recovery should proceed for seed-2
    const commitEpoch = Math.floor(new Date("2026-01-02T00:00:00.000Z").getTime() / 1000);

    const mockExecFileAsync = vi.fn().mockImplementation((_cmd: string, args: string[]) => {
      if (args[0] === "rev-parse") {
        // Both local (completed first-pass) and remote (secondary pass) branches exist
        return Promise.resolve({ stdout: "abc123\n", stderr: "" });
      }
      if (args[0] === "log" && args.includes("--format=%ct")) {
        // Commit after run creation — not a stale ref → recover
        return Promise.resolve({ stdout: `${commitEpoch}\n`, stderr: "" });
      }
      if (args[0] === "diff") {
        return Promise.resolve({ stdout: "src/foo.ts\n", stderr: "" });
      }
      return Promise.reject(new Error("unexpected git call"));
    });

    const result = await queue.reconcile(db, "/tmp/repo", mockExecFileAsync);

    expect(result.enqueued).toBe(2);
    expect(queue.list("pending")).toHaveLength(2);
  });

  it("deduplicates by seed_id in the secondary pass — only recovers the oldest run, not a newer one for the same seed", async () => {
    // Simulate: old run crashed after push (status stuck at "running"),
    // dispatcher later created a new run for the same seed (also "running", not yet pushed).
    // Both share the same seed_id → same remote branch name.
    //
    // run-old: created 2026-01-01, pushed branch at 2026-01-01T12:00Z
    // run-new: created 2026-01-02 (after the push)
    //
    // The timestamp guard checks commitEpoch >= run.created_at:
    //   run-old (oldest, processed first): commitEpoch (Jan 1 noon) >= run-old.created_at (Jan 1 midnight) ✓ → recover
    //   run-new: skipped by seenSeedIds deduplication (seed-1 already seen)
    db.prepare(
      `INSERT INTO runs (id, project_id, seed_id, agent_type, status, created_at)
       VALUES ('run-old', 'proj-1', 'seed-1', 'worker', 'running', '2026-01-01T00:00:00.000Z')`
    ).run();
    db.prepare(
      `INSERT INTO runs (id, project_id, seed_id, agent_type, status, created_at)
       VALUES ('run-new', 'proj-1', 'seed-1', 'worker', 'running', '2026-01-02T00:00:00.000Z')`
    ).run();

    // Commit epoch: 2026-01-01T12:00Z — after run-old was created, before run-new.
    // The guard passes for run-old (oldest, processed first by ORDER BY created_at ASC).
    // run-new is never tested because seenSeedIds deduplication skips it.
    const commitEpoch = Math.floor(new Date("2026-01-01T12:00:00.000Z").getTime() / 1000);

    const mockExecFileAsync = vi.fn().mockImplementation((_cmd: string, args: string[]) => {
      if (args[0] === "rev-parse" && args[2] === "refs/remotes/origin/foreman/seed-1") {
        // Remote branch exists — pushed by run-old before it crashed
        return Promise.resolve({ stdout: "abc123\n", stderr: "" });
      }
      if (args[0] === "log" && args.includes("--format=%ct")) {
        // Commit at Jan 1 noon — after run-old was created → run-old is recovered
        return Promise.resolve({ stdout: `${commitEpoch}\n`, stderr: "" });
      }
      if (args[0] === "diff") {
        return Promise.resolve({ stdout: "src/foo.ts\n", stderr: "" });
      }
      return Promise.reject(new Error("unexpected git call"));
    });

    const result = await queue.reconcile(db, "/tmp/repo", mockExecFileAsync);

    // Only one entry should be enqueued (deduplicated by seed_id)
    expect(result.enqueued).toBe(1);
    const entries = queue.list("pending");
    expect(entries).toHaveLength(1);

    // The oldest run (run-old, created 2026-01-01) should be the one recovered
    expect(entries[0].run_id).toBe("run-old");

    // run-old should be marked completed (recovered)
    const oldRun = db.prepare("SELECT status FROM runs WHERE id = ?").get("run-old") as { status: string };
    expect(oldRun.status).toBe("completed");

    // run-new should remain "running" — it was NOT falsely marked completed
    const newRun = db.prepare("SELECT status FROM runs WHERE id = ?").get("run-new") as { status: string };
    expect(newRun.status).toBe("running");
  });
});
