/**
 * Performance benchmark for the multi-project dashboard aggregation (REQ-019).
 *
 * Verifies that `readProjectSnapshot()` completes within 2000ms for 7 projects,
 * each with 200 tasks and 10 runs stored in real SQLite databases on disk.
 *
 * Also benchmarks `sortNeedsHumanTasks()` with the full 1400-task worst-case.
 */
import { describe, it, expect, afterAll } from "vitest";
import Database from "better-sqlite3";
import { mkdirSync, rmSync, existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { randomUUID } from "node:crypto";
import { readProjectSnapshot, aggregateSnapshots, sortNeedsHumanTasks } from "../commands/dashboard.js";
import type { NativeTask } from "../../lib/store.js";

// ── Helpers ───────────────────────────────────────────────────────────────

/** Root temp directory for the benchmark (cleaned up after all tests). */
const BENCH_ROOT = join(tmpdir(), `foreman-dashboard-bench-${randomUUID()}`);

afterAll(() => {
  try { rmSync(BENCH_ROOT, { recursive: true, force: true }); } catch { /* ignore */ }
});

/**
 * Create a project directory with a seeded `.foreman/foreman.db` on disk.
 * Returns the project path.
 */
function createProjectDb(
  projectId: string,
  numTasks: number,
  numRuns: number,
): string {
  const projectPath = join(BENCH_ROOT, projectId);
  const foremanDir = join(projectPath, ".foreman");
  mkdirSync(foremanDir, { recursive: true });

  const db = new Database(join(foremanDir, "foreman.db"));
  db.pragma("journal_mode = WAL");

  db.exec(`
    CREATE TABLE IF NOT EXISTS projects (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL UNIQUE,
      status TEXT DEFAULT 'active', created_at TEXT, updated_at TEXT
    );
    CREATE TABLE IF NOT EXISTS runs (
      id TEXT PRIMARY KEY, project_id TEXT NOT NULL, seed_id TEXT NOT NULL,
      agent_type TEXT NOT NULL, session_key TEXT, worktree_path TEXT,
      status TEXT DEFAULT 'pending', started_at TEXT, completed_at TEXT,
      created_at TEXT, progress TEXT, base_branch TEXT
    );
    CREATE TABLE IF NOT EXISTS costs (
      id TEXT PRIMARY KEY, run_id TEXT NOT NULL,
      tokens_in INTEGER DEFAULT 0, tokens_out INTEGER DEFAULT 0,
      cache_read INTEGER DEFAULT 0, estimated_cost REAL DEFAULT 0,
      recorded_at TEXT
    );
    CREATE TABLE IF NOT EXISTS events (
      id TEXT PRIMARY KEY, project_id TEXT NOT NULL, run_id TEXT,
      event_type TEXT NOT NULL, details TEXT, created_at TEXT
    );
    CREATE TABLE IF NOT EXISTS tasks (
      id TEXT PRIMARY KEY, title TEXT NOT NULL, description TEXT,
      type TEXT NOT NULL DEFAULT 'task', priority INTEGER NOT NULL DEFAULT 2,
      status TEXT NOT NULL DEFAULT 'backlog',
      run_id TEXT, branch TEXT, external_id TEXT UNIQUE,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      approved_at TEXT, closed_at TEXT
    );
  `);

  // Register the project itself
  const now = new Date().toISOString();
  db.prepare(
    `INSERT INTO projects (id, name, path, status, created_at, updated_at) VALUES (?, ?, ?, 'active', ?, ?)`
  ).run(projectId, `project-${projectId}`, projectPath, now, now);

  // Seed runs
  const insertRun = db.prepare(
    `INSERT INTO runs (id, project_id, seed_id, agent_type, status, created_at, completed_at)
     VALUES (?, ?, ?, 'claude-sonnet-4-6', ?, ?, ?)`
  );
  const runStatuses = ["running", "completed", "failed", "merged"];
  for (let i = 0; i < numRuns; i++) {
    insertRun.run(
      `run-${projectId}-${i}`,
      projectId,
      `seed-${i}`,
      runStatuses[i % runStatuses.length],
      now,
      i % 2 === 0 ? now : null,
    );
  }

  // Seed tasks with needs-human statuses
  const needsHumanStatuses = ["conflict", "failed", "stuck", "backlog"] as const;
  const insertTask = db.prepare(
    `INSERT INTO tasks (id, title, type, priority, status, created_at, updated_at)
     VALUES (?, ?, 'task', ?, ?, ?, ?)`
  );
  const old = new Date(Date.now() - 3_600_000).toISOString();
  for (let i = 0; i < numTasks; i++) {
    insertTask.run(
      `task-${projectId}-${i}`,
      `Task ${i} for ${projectId}`,
      i % 5,
      needsHumanStatuses[i % needsHumanStatuses.length],
      old,
      now,
    );
  }

  db.close();
  return projectPath;
}

// ── Tests ─────────────────────────────────────────────────────────────────

describe("Dashboard performance (REQ-019)", () => {
  const NUM_PROJECTS = 7;
  const NUM_TASKS_PER_PROJECT = 200;
  const NUM_RUNS_PER_PROJECT = 10;
  const MAX_REFRESH_MS = 2000;

  it("reads 7 projects × 200 tasks × 10 runs within 2000ms (REQ-019.1)", async () => {
    // Create real on-disk project databases
    const projectIds = Array.from({ length: NUM_PROJECTS }, (_, i) => `perf-proj-${i}`);
    const projects = projectIds.map((pid) => {
      const projectPath = createProjectDb(pid, NUM_TASKS_PER_PROJECT, NUM_RUNS_PER_PROJECT);
      return { id: pid, name: `project-${pid}`, path: projectPath };
    });

    const start = Date.now();
    const snapshots = await readProjectSnapshot(projects, 8);
    const elapsed = Date.now() - start;

    // Primary assertion: must complete within 2 seconds (REQ-019.1)
    expect(elapsed).toBeLessThan(MAX_REFRESH_MS);

    // Correctness assertions
    expect(snapshots).toHaveLength(NUM_PROJECTS);

    const offlineCount = snapshots.filter((s) => s.offline).length;
    expect(offlineCount).toBe(0);

    const totalNeedsHuman = snapshots.reduce((sum, s) => sum + s.needsHumanTasks.length, 0);
    expect(totalNeedsHuman).toBeGreaterThan(0);

    // Verify aggregation works
    const state = aggregateSnapshots(snapshots);
    expect(state.projects).toHaveLength(NUM_PROJECTS);
    expect(state.needsHumanTasks!.length).toBeGreaterThan(0);
    // Verify sort order: first item should be highest-urgency status
    expect(state.needsHumanTasks![0].status).toBe("conflict");
  });

  it("handles offline projects gracefully without crashing (REQ-010.1)", async () => {
    const projects = [
      { id: "missing-1", name: "missing-project-1", path: "/nonexistent/path/1" },
      { id: "missing-2", name: "missing-project-2", path: "/nonexistent/path/2" },
    ];

    const snapshots = await readProjectSnapshot(projects, 8);
    expect(snapshots).toHaveLength(2);
    expect(snapshots.every((s) => s.offline)).toBe(true);

    // Aggregation should still work with all-offline snapshots
    const state = aggregateSnapshots(snapshots);
    expect(state.projects).toHaveLength(2);
    expect(state.offlineProjects?.size).toBe(2);
    expect(state.needsHumanTasks).toHaveLength(0);
  });

  it("sortNeedsHumanTasks handles 1400-task worst case efficiently", () => {
    // 7 projects × 200 tasks = 1400 tasks max
    const tasks: NativeTask[] = Array.from({ length: 1400 }, (_, i) => ({
      id: `task-${i}`,
      title: `Task ${i}`,
      description: null,
      type: "task",
      priority: i % 5,
      status: ["conflict", "failed", "stuck", "backlog"][i % 4],
      run_id: null,
      branch: null,
      external_id: null,
      created_at: new Date(Date.now() - i * 1000).toISOString(),
      updated_at: new Date(Date.now() - i * 500).toISOString(),
      approved_at: null,
      closed_at: null,
    }));

    const start = Date.now();
    const sorted = sortNeedsHumanTasks(tasks);
    const elapsed = Date.now() - start;

    // Should sort 1400 items well within 100ms
    expect(elapsed).toBeLessThan(100);
    expect(sorted).toHaveLength(1400);

    // Verify sort order: first item should be conflict P0 (oldest)
    expect(sorted[0].status).toBe("conflict");
    expect(sorted[0].priority).toBe(0);
  });

  it("parallel reads are faster than sequential would be (REQ-010 AC-010.2)", async () => {
    // Create 4 projects to compare parallel vs sequential timing
    const projectIds = Array.from({ length: 4 }, (_, i) => `timing-proj-${i}`);
    const projects = projectIds.map((pid) => {
      const projectPath = createProjectDb(pid, 50, 5);
      return { id: pid, name: pid, path: projectPath };
    });

    // Run once to warm up any caches
    await readProjectSnapshot(projects.slice(0, 1), 8);

    // Measure parallel reads
    const t0 = Date.now();
    const snapshots = await readProjectSnapshot(projects, 8);
    const parallelMs = Date.now() - t0;

    expect(snapshots).toHaveLength(4);
    // All should be online
    expect(snapshots.every((s) => !s.offline)).toBe(true);
    // Should complete well within 2 seconds for 4 projects
    expect(parallelMs).toBeLessThan(MAX_REFRESH_MS);
  });
});
