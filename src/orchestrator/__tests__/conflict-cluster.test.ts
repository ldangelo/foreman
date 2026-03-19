import { describe, it, expect, beforeEach } from "vitest";
import Database from "better-sqlite3";
import {
  buildOverlapGraph,
  findClusters,
  orderByCluster,
  reCluster,
} from "../conflict-cluster.js";
import { MergeQueue } from "../merge-queue.js";
import type { MergeQueueEntry } from "../merge-queue.js";

// ── Helpers ──────────────────────────────────────────────────────────────

/** Create an in-memory MergeQueueEntry without touching SQLite. */
function entry(
  id: number,
  files: string[],
  enqueuedAt?: string
): MergeQueueEntry {
  return {
    id,
    branch_name: `foreman/seed-${id}`,
    seed_id: `seed-${id}`,
    run_id: `run-${id}`,
    agent_name: null,
    files_modified: files,
    enqueued_at: enqueuedAt ?? new Date(Date.now() + id * 1000).toISOString(),
    started_at: null,
    completed_at: null,
    status: "pending",
    resolved_tier: null,
    error: null,
    retry_count: 0,
    last_attempted_at: null,
  };
}

// Minimal schema for MergeQueue integration tests
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
  projectId = "proj-1"
): void {
  db.prepare(
    `INSERT INTO runs (id, project_id, seed_id, agent_type, status, created_at)
     VALUES (?, ?, ?, 'worker', 'completed', datetime('now'))`
  ).run(id, projectId, seedId);
}

// ── buildOverlapGraph ────────────────────────────────────────────────────

describe("buildOverlapGraph", () => {
  it("returns empty graph for empty entries", () => {
    const graph = buildOverlapGraph([]);
    expect(graph.size).toBe(0);
  });

  it("returns graph with no edges for independent entries", () => {
    const entries = [
      entry(1, ["src/a.ts"]),
      entry(2, ["src/b.ts"]),
      entry(3, ["src/c.ts"]),
    ];
    const graph = buildOverlapGraph(entries);
    // Each node present but with empty adjacency
    expect(graph.get(1)?.size ?? 0).toBe(0);
    expect(graph.get(2)?.size ?? 0).toBe(0);
    expect(graph.get(3)?.size ?? 0).toBe(0);
  });

  it("creates edges for entries sharing a file", () => {
    const entries = [
      entry(1, ["src/shared.ts", "src/a.ts"]),
      entry(2, ["src/shared.ts", "src/b.ts"]),
    ];
    const graph = buildOverlapGraph(entries);
    expect(graph.get(1)?.has(2)).toBe(true);
    expect(graph.get(2)?.has(1)).toBe(true);
  });

  it("handles single entry", () => {
    const graph = buildOverlapGraph([entry(1, ["src/a.ts"])]);
    expect(graph.size).toBe(1);
    expect(graph.get(1)?.size ?? 0).toBe(0);
  });

  it("handles entries with empty files_modified", () => {
    const entries = [entry(1, []), entry(2, [])];
    const graph = buildOverlapGraph(entries);
    expect(graph.get(1)?.size ?? 0).toBe(0);
    expect(graph.get(2)?.size ?? 0).toBe(0);
  });
});

// ── findClusters ─────────────────────────────────────────────────────────

describe("findClusters", () => {
  it("returns empty array for empty graph", () => {
    const clusters = findClusters(new Map());
    expect(clusters).toEqual([]);
  });

  it("returns each independent node as its own cluster", () => {
    const graph = new Map<number, Set<number>>([
      [1, new Set()],
      [2, new Set()],
      [3, new Set()],
    ]);
    const clusters = findClusters(graph);
    expect(clusters).toHaveLength(3);
    // Each cluster has exactly one member
    for (const cluster of clusters) {
      expect(cluster).toHaveLength(1);
    }
  });

  it("groups connected nodes into one cluster", () => {
    const graph = new Map<number, Set<number>>([
      [1, new Set([2])],
      [2, new Set([1])],
      [3, new Set()],
    ]);
    const clusters = findClusters(graph);
    expect(clusters).toHaveLength(2);
    const big = clusters.find((c) => c.length === 2)!;
    expect(big.sort()).toEqual([1, 2]);
  });

  it("handles transitive overlap (A-B, B-C => A,B,C same cluster)", () => {
    const graph = new Map<number, Set<number>>([
      [1, new Set([2])],
      [2, new Set([1, 3])],
      [3, new Set([2])],
    ]);
    const clusters = findClusters(graph);
    expect(clusters).toHaveLength(1);
    expect(clusters[0].sort()).toEqual([1, 2, 3]);
  });

  it("finds multiple disjoint clusters", () => {
    const graph = new Map<number, Set<number>>([
      [1, new Set([2])],
      [2, new Set([1])],
      [3, new Set([4])],
      [4, new Set([3])],
    ]);
    const clusters = findClusters(graph);
    expect(clusters).toHaveLength(2);
  });
});

// ── orderByCluster ───────────────────────────────────────────────────────

describe("orderByCluster", () => {
  it("returns empty array for empty entries", () => {
    expect(orderByCluster([])).toEqual([]);
  });

  it("maintains FIFO order for independent entries", () => {
    const t1 = "2026-01-01T00:00:00Z";
    const t2 = "2026-01-01T00:01:00Z";
    const t3 = "2026-01-01T00:02:00Z";
    const entries = [
      entry(1, ["a.ts"], t1),
      entry(2, ["b.ts"], t2),
      entry(3, ["c.ts"], t3),
    ];
    const ordered = orderByCluster(entries);
    expect(ordered.map((e) => e.id)).toEqual([1, 2, 3]);
  });

  it("groups overlapping entries consecutively while maintaining FIFO within cluster", () => {
    const t1 = "2026-01-01T00:00:00Z";
    const t2 = "2026-01-01T00:01:00Z";
    const t3 = "2026-01-01T00:02:00Z";
    const t4 = "2026-01-01T00:03:00Z";

    // Entry 1 and 3 overlap (share file X), entry 2 and 4 are independent
    const entries = [
      entry(1, ["X.ts"], t1),
      entry(2, ["Y.ts"], t2),
      entry(3, ["X.ts", "Z.ts"], t3),
      entry(4, ["W.ts"], t4),
    ];
    const ordered = orderByCluster(entries);
    const ids = ordered.map((e) => e.id);

    // Entries 1 and 3 must be adjacent
    const idx1 = ids.indexOf(1);
    const idx3 = ids.indexOf(3);
    expect(Math.abs(idx1 - idx3)).toBe(1);

    // Entry 1 should come before 3 (FIFO within cluster)
    expect(idx1).toBeLessThan(idx3);
  });

  it("orders clusters by earliest enqueued_at in the cluster", () => {
    const t1 = "2026-01-01T00:00:00Z";
    const t2 = "2026-01-01T00:01:00Z";
    const t3 = "2026-01-01T00:02:00Z";
    const t4 = "2026-01-01T00:03:00Z";

    // Cluster A: entries 2,4 share file (earliest is t2)
    // Cluster B: entries 1,3 share file (earliest is t1)
    const entries = [
      entry(1, ["A.ts"], t1),
      entry(2, ["B.ts"], t2),
      entry(3, ["A.ts"], t3),
      entry(4, ["B.ts"], t4),
    ];
    const ordered = orderByCluster(entries);
    const ids = ordered.map((e) => e.id);

    // Cluster B (entries 1,3) should come first since t1 < t2
    expect(ids.indexOf(1)).toBeLessThan(ids.indexOf(2));
    expect(ids.indexOf(3)).toBeLessThan(ids.indexOf(4));
  });
});

// ── reCluster ────────────────────────────────────────────────────────────

describe("reCluster", () => {
  it("returns same clusters when merged files do not overlap with remaining", () => {
    const entries = [
      entry(1, ["a.ts"]),
      entry(2, ["b.ts"]),
    ];
    const clusters = reCluster(entries, ["unrelated.ts"]);
    expect(clusters).toHaveLength(2);
  });

  it("merges previously independent entries when they share a file", () => {
    const entries = [
      entry(1, ["shared.ts", "a.ts"]),
      entry(2, ["shared.ts", "b.ts"]),
    ];
    const clusters = reCluster(entries, ["unrelated.ts"]);
    expect(clusters).toHaveLength(1);
  });

  it("adds edges for entries whose files overlap with mergedFiles", () => {
    const entries = [
      entry(1, ["X.ts"]),
      entry(2, ["X.ts"]),
    ];
    const clusters = reCluster(entries, ["X.ts"]);
    expect(clusters).toHaveLength(1);
    expect(clusters[0].sort()).toEqual([1, 2]);
  });

  it("returns empty clusters for empty entries", () => {
    expect(reCluster([], ["foo.ts"])).toEqual([]);
  });

  it("does not merge entries when only one overlaps with mergedFiles", () => {
    const entries = [
      entry(1, ["A.ts"]),
      entry(2, ["B.ts"]),
    ];
    const clusters = reCluster(entries, ["A.ts"]);
    // Entry 1 and 2 still independent -- mergedFiles creates overlap only
    // between entries that BOTH touch mergedFiles
    expect(clusters).toHaveLength(2);
  });

  it("creates cluster when two entries both overlap with mergedFiles", () => {
    const entries = [
      entry(1, ["A.ts"]),
      entry(2, ["B.ts"]),
    ];
    // Both entries touch files in mergedFiles
    const clusters = reCluster(entries, ["A.ts", "B.ts"]);
    // Now both entries overlap with mergedFiles, creating a new edge
    expect(clusters).toHaveLength(1);
  });
});

// ── MergeQueue.dequeueOrdered integration ────────────────────────────────

describe("MergeQueue.dequeueOrdered (cluster-aware)", () => {
  let db: Database.Database;
  let queue: MergeQueue;

  beforeEach(() => {
    db = createTestDb();
    insertProject(db);
    insertRun(db, "run-1", "seed-1");
    insertRun(db, "run-2", "seed-2");
    insertRun(db, "run-3", "seed-3");
    insertRun(db, "run-4", "seed-4");
    queue = new MergeQueue(db);
  });

  it("returns null for empty queue", () => {
    expect(queue.dequeueOrdered()).toBeNull();
  });

  it("returns single pending entry", () => {
    queue.enqueue({
      branchName: "foreman/seed-1",
      seedId: "seed-1",
      runId: "run-1",
      filesModified: ["a.ts"],
    });
    const result = queue.dequeueOrdered();
    expect(result).not.toBeNull();
    expect(result!.status).toBe("merging");
    expect(result!.seed_id).toBe("seed-1");
  });

  it("dequeues entries in cluster-aware order", () => {
    // Enqueue: entry 1 (X.ts), entry 2 (Y.ts), entry 3 (X.ts, Z.ts)
    // Entry 1 and 3 overlap. Cluster order: [1,3], [2]
    queue.enqueue({
      branchName: "foreman/seed-1",
      seedId: "seed-1",
      runId: "run-1",
      filesModified: ["X.ts"],
    });
    queue.enqueue({
      branchName: "foreman/seed-2",
      seedId: "seed-2",
      runId: "run-2",
      filesModified: ["Y.ts"],
    });
    queue.enqueue({
      branchName: "foreman/seed-3",
      seedId: "seed-3",
      runId: "run-3",
      filesModified: ["X.ts", "Z.ts"],
    });

    // First call: pending = [1,2,3]. Clusters: {1,3} (share X.ts), {2}.
    // Cluster {1,3} is first (earliest enqueued_at). Entry 1 dequeued.
    const first = queue.dequeueOrdered();
    expect(first!.seed_id).toBe("seed-1");

    // Second call: pending = [2,3]. Entry 3 has X.ts but no pending partner
    // shares it, so clusters are {2}, {3}. FIFO: entry 2 (earlier) first.
    const second = queue.dequeueOrdered();
    expect(second!.seed_id).toBe("seed-2");

    const third = queue.dequeueOrdered();
    expect(third!.seed_id).toBe("seed-3");

    const fourth = queue.dequeueOrdered();
    expect(fourth).toBeNull();
  });

  it("skips non-pending entries", () => {
    queue.enqueue({
      branchName: "foreman/seed-1",
      seedId: "seed-1",
      runId: "run-1",
      filesModified: ["a.ts"],
    });
    queue.enqueue({
      branchName: "foreman/seed-2",
      seedId: "seed-2",
      runId: "run-2",
      filesModified: ["b.ts"],
    });
    // Mark seed-1 entry as already merging
    const first = queue.list("pending")[0];
    queue.updateStatus(first.id, "merging");

    const result = queue.dequeueOrdered();
    expect(result!.seed_id).toBe("seed-2");
  });
});

// ── getOrderedPending ────────────────────────────────────────────────────

describe("MergeQueue.getOrderedPending", () => {
  let db: Database.Database;
  let queue: MergeQueue;

  beforeEach(() => {
    db = createTestDb();
    insertProject(db);
    insertRun(db, "run-1", "seed-1");
    insertRun(db, "run-2", "seed-2");
    insertRun(db, "run-3", "seed-3");
  });

  it("returns pending entries in cluster-aware order", () => {
    queue = new MergeQueue(db);
    queue.enqueue({
      branchName: "foreman/seed-1",
      seedId: "seed-1",
      runId: "run-1",
      filesModified: ["X.ts"],
    });
    queue.enqueue({
      branchName: "foreman/seed-2",
      seedId: "seed-2",
      runId: "run-2",
      filesModified: ["Y.ts"],
    });
    queue.enqueue({
      branchName: "foreman/seed-3",
      seedId: "seed-3",
      runId: "run-3",
      filesModified: ["X.ts", "Z.ts"],
    });

    const ordered = queue.getOrderedPending();
    const ids = ordered.map((e) => e.seed_id);
    // seed-1 and seed-3 share X.ts, should be adjacent
    const idx1 = ids.indexOf("seed-1");
    const idx3 = ids.indexOf("seed-3");
    expect(Math.abs(idx1 - idx3)).toBe(1);
    expect(idx1).toBeLessThan(idx3);
  });

  it("returns empty array when no pending entries", () => {
    queue = new MergeQueue(db);
    expect(queue.getOrderedPending()).toEqual([]);
  });
});
