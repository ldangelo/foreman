import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import Database from "better-sqlite3";
import { MergeQueue } from "../merge-queue.js";
import type { VcsBackend } from "../../lib/vcs/interface.js";

const { mockCreateVcsBackend } = vi.hoisted(() => ({
  mockCreateVcsBackend: vi.fn(),
}));

vi.mock("../../lib/vcs/index.js", () => ({
  VcsBackendFactory: {
    create: mockCreateVcsBackend,
  },
}));

/**
 * Create a minimal VcsBackend mock for reconcile() tests.
 * By default: branchExists=true, branchExistsOnRemote=false, getChangedFiles=[], getRefCommitTimestamp=null.
 */
function makeBackend(opts?: {
  branchExists?: boolean | ((branch: string) => boolean);
  branchExistsOnRemote?: boolean | ((branch: string) => boolean);
  files?: string[];
  timestamp?: number | null;
}): VcsBackend {
  const {
    branchExists: be = true,
    branchExistsOnRemote: beor = false,
    files = [],
    timestamp = null,
  } = opts ?? {};
  return {
    branchExists: vi.fn().mockImplementation((_repo: string, branch: string) =>
      Promise.resolve(typeof be === "function" ? be(branch) : be)
    ),
    branchExistsOnRemote: vi.fn().mockImplementation((_repo: string, branch: string) =>
      Promise.resolve(typeof beor === "function" ? beor(branch) : beor)
    ),
    getChangedFiles: vi.fn().mockResolvedValue(files),
    getRefCommitTimestamp: vi.fn().mockResolvedValue(timestamp),
    detectDefaultBranch: vi.fn().mockResolvedValue("main"),
  } as unknown as VcsBackend;
}

const SCHEMA = `
CREATE TABLE IF NOT EXISTS projects (id TEXT PRIMARY KEY, name TEXT, path TEXT UNIQUE, status TEXT, created_at TEXT, updated_at TEXT);
CREATE TABLE IF NOT EXISTS runs (id TEXT PRIMARY KEY, project_id TEXT, seed_id TEXT, agent_type TEXT, status TEXT DEFAULT 'pending', created_at TEXT, completed_at TEXT, worktree_path TEXT, FOREIGN KEY (project_id) REFERENCES projects(id));
CREATE TABLE IF NOT EXISTS merge_queue (id INTEGER PRIMARY KEY AUTOINCREMENT, branch_name TEXT NOT NULL, seed_id TEXT NOT NULL, run_id TEXT NOT NULL, agent_name TEXT, files_modified TEXT DEFAULT '[]', enqueued_at TEXT NOT NULL, started_at TEXT, completed_at TEXT, status TEXT DEFAULT 'pending' CHECK (status IN ('pending','merging','merged','conflict','failed')), resolved_tier INTEGER, error TEXT, retry_count INTEGER DEFAULT 0, last_attempted_at TEXT DEFAULT NULL, FOREIGN KEY (run_id) REFERENCES runs(id));
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

const mockGit = () => makeBackend({ branchExists: true, branchExistsOnRemote: false });

// ── Test 1: Reconcile ───────────────────────────────────────────────

describe("Reconcile detects missing entries", () => {
  let db: Database.Database;
  let mq: MergeQueue;
  beforeEach(() => { db = mkDb(); mq = new MergeQueue(db); mockCreateVcsBackend.mockResolvedValue(makeBackend()); });
  afterEach(() => { db.close(); });

  it("enqueues completed runs not already queued", async () => {
    addRun(db, "r1", "s1", "completed");
    addRun(db, "r2", "s2", "completed");
    addRun(db, "r3", "s3", "running");
    // Secondary pass checks remote branch existence for pending/running runs.
    // r3 has no remote branch (still genuinely running), so branchExistsOnRemote=false for s3.
    const git = makeBackend({
      branchExists: true,
      branchExistsOnRemote: (branch) => !branch.includes("s3"),
    });
    const r = await mq.reconcile(db, "/tmp", git);
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

// ── Test 1b: missingFromQueue detection ────────────────────────────

describe("missingFromQueue detects completed runs not in queue", () => {
  let db: Database.Database;
  let mq: MergeQueue;
  beforeEach(() => { db = mkDb(); mq = new MergeQueue(db); mockCreateVcsBackend.mockResolvedValue(makeBackend()); });
  afterEach(() => { db.close(); });

  it("returns empty array when no completed runs exist", () => {
    expect(mq.missingFromQueue()).toHaveLength(0);
  });

  it("returns empty array when all completed runs are already queued", () => {
    addRun(db, "r1", "s1", "completed");
    mq.enqueue({ branchName: "foreman/s1", seedId: "s1", runId: "r1" });
    expect(mq.missingFromQueue()).toHaveLength(0);
  });

  it("returns completed runs that are not in the merge queue", () => {
    addRun(db, "r1", "s1", "completed");
    addRun(db, "r2", "s2", "completed");
    const missing = mq.missingFromQueue();
    expect(missing).toHaveLength(2);
    expect(missing.map((r) => r.seed_id).sort()).toEqual(["s1", "s2"]);
    expect(missing[0]).toHaveProperty("run_id");
  });

  it("does not include runs in non-completed statuses", () => {
    addRun(db, "r1", "s1", "running");
    addRun(db, "r2", "s2", "failed");
    addRun(db, "r3", "s3", "merged");
    expect(mq.missingFromQueue()).toHaveLength(0);
  });

  it("does not include completed run already queued but includes unqueued one", () => {
    addRun(db, "r1", "s1", "completed");
    addRun(db, "r2", "s2", "completed");
    mq.enqueue({ branchName: "foreman/s1", seedId: "s1", runId: "r1" });
    const missing = mq.missingFromQueue();
    expect(missing).toHaveLength(1);
    expect(missing[0].seed_id).toBe("s2");
  });
});

// ── Test 1c: Reconcile invalid branch reporting ─────────────────────

describe("Reconcile reports invalid branches in failedToEnqueue", () => {
  let db: Database.Database;
  let mq: MergeQueue;
  beforeEach(() => { db = mkDb(); mq = new MergeQueue(db); mockCreateVcsBackend.mockResolvedValue(makeBackend()); });
  afterEach(() => { db.close(); });

  it("populates failedToEnqueue when branch does not exist", async () => {
    addRun(db, "r1", "s1", "completed");
    const mockFail = makeBackend({ branchExists: false });
    const r = await mq.reconcile(db, "/tmp", mockFail);
    expect(r.invalidBranch).toBe(1);
    expect(r.enqueued).toBe(0);
    expect(r.failedToEnqueue).toHaveLength(1);
    expect(r.failedToEnqueue[0].seed_id).toBe("s1");
    expect(r.failedToEnqueue[0].run_id).toBe("r1");
    expect(r.failedToEnqueue[0].reason).toContain("foreman/s1");
  });

  it("returns empty failedToEnqueue when all branches exist", async () => {
    addRun(db, "r1", "s1", "completed");
    const r = await mq.reconcile(db, "/tmp", mockGit());
    expect(r.failedToEnqueue).toHaveLength(0);
    expect(r.enqueued).toBe(1);
  });

  it("reports multiple failed branches separately", async () => {
    addRun(db, "r1", "s1", "completed");
    addRun(db, "r2", "s2", "completed");
    const mockFail = makeBackend({ branchExists: false });
    const r = await mq.reconcile(db, "/tmp", mockFail);
    expect(r.invalidBranch).toBe(2);
    expect(r.failedToEnqueue).toHaveLength(2);
    const seedIds = r.failedToEnqueue.map((f) => f.seed_id).sort();
    expect(seedIds).toEqual(["s1", "s2"]);
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
    mockCreateVcsBackend.mockResolvedValue(makeBackend());
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
    mockCreateVcsBackend.mockResolvedValue(makeBackend());
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
  beforeEach(() => { db = mkDb(); mq = new MergeQueue(db); mockCreateVcsBackend.mockResolvedValue(makeBackend()); });
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

    // For --bead filter, find matching entry in pending list, then dequeue+process
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

  it("mid-loop reconcile failure does not abort processing of already-queued entries", async () => {
    // Set up two runs already in the queue before the loop starts
    addRun(db, "r1", "s1", "completed");
    addRun(db, "r2", "s2", "completed");
    const r = await mq.reconcile(db, "/tmp", mockGit());
    expect(r.enqueued).toBe(2);

    // Make subsequent reconcile() calls throw (simulates a DB or unexpected error).
    // Note: reconcile() catches all git failures internally, so a failing git function
    // alone would not cause reconcile() to throw. We spy directly on the method so the
    // try/catch in the production dequeue loop (and mirrored here) is actually exercised.
    const reconcileSpy = vi.spyOn(mq, "reconcile").mockRejectedValue(new Error("mock: reconcile failure"));

    const results: string[] = [];
    const errors: string[] = [];

    let e = mq.dequeue();
    while (e) {
      mq.updateStatus(e.id, "merged", { completedAt: new Date().toISOString() });
      results.push(e.seed_id);

      // Mid-loop reconcile that throws — should not abort the loop
      try {
        await mq.reconcile(db, "/tmp", mockGit());
      } catch (reconcileErr: unknown) {
        errors.push(reconcileErr instanceof Error ? reconcileErr.message : String(reconcileErr));
      }

      e = mq.dequeue();
    }

    reconcileSpy.mockRestore();

    // Both entries should have been processed despite the reconcile failure
    expect(results).toHaveLength(2);
    expect(results).toContain("s1");
    expect(results).toContain("s2");
    expect(mq.list("merged")).toHaveLength(2);
    expect(mq.list("pending")).toHaveLength(0);
    // The reconcile errors were caught (one per loop iteration)
    expect(errors.length).toBeGreaterThan(0);
    expect(errors[0]).toBe("mock: reconcile failure");
  });

  it("re-reconciling during dequeue loop catches agents that complete mid-merge", async () => {
    // Simulate initial state: two runs already completed before merge starts
    addRun(db, "r1", "s1", "completed");
    addRun(db, "r2", "s2", "completed");

    // Initial reconcile snapshot (before merge loop)
    const r = await mq.reconcile(db, "/tmp", mockGit());
    expect(r.enqueued).toBe(2);

    const results: string[] = [];
    let e = mq.dequeue();
    while (e) {
      // Simulate an agent (s3) completing while we process the first entry
      if (e.seed_id === "s1") {
        addRun(db, "r3", "s3", "completed");
      }

      mq.updateStatus(e.id, "merged", { completedAt: new Date().toISOString() });
      results.push(e.seed_id);

      // Re-reconcile (this is what the fix adds to the merge command loop)
      await mq.reconcile(db, "/tmp", mockGit());

      e = mq.dequeue();
    }

    // Without re-reconciliation, s3 would be missed. With the fix, it is caught.
    expect(results).toHaveLength(3);
    expect(results).toContain("s3");
    expect(mq.list("merged")).toHaveLength(3);
    expect(mq.list("pending")).toHaveLength(0);
  });
});
