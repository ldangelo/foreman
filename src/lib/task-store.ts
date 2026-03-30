/**
 * NativeTaskStore — wraps the native `tasks` SQLite table for use as a
 * task-tracking back-end inside the Dispatcher.
 *
 * Implements a subset of ITaskClient focused on the Dispatcher's needs:
 *   - hasNativeTasks() — coexistence check (REQ-014)
 *   - list()           — query tasks with optional status filter (REQ-017)
 *   - claim()          — atomically claim a task for a run (REQ-020)
 *   - updatePhase()    — update phase column (no-op when taskId is null)
 *   - updateStatus()   — update task status
 */

import type { Database } from "better-sqlite3";
import type { Issue } from "./task-client.js";

// ── Row type matching TASKS_SCHEMA ───────────────────────────────────────

export interface TaskRow {
  id: string;
  title: string;
  description: string | null;
  type: string;
  priority: number;
  status: string;
  run_id: string | null;
  branch: string | null;
  external_id: string | null;
  created_at: string;
  updated_at: string;
  approved_at: string | null;
  closed_at: string | null;
}

// ── Helpers ──────────────────────────────────────────────────────────────

/**
 * Map a numeric priority (0–4) to the string format expected by Issue.priority.
 * Stores the value as-is ("0"–"4") so normalizePriority() works correctly.
 */
function rowToIssue(row: TaskRow): Issue {
  return {
    id: row.id,
    title: row.title,
    type: row.type,
    priority: String(row.priority),
    status: row.status,
    assignee: null,
    parent: null,
    created_at: row.created_at,
    updated_at: row.updated_at,
    description: row.description ?? null,
    labels: [],
  };
}

// ── NativeTaskStore ──────────────────────────────────────────────────────

/**
 * Provides read/write access to the `tasks` table inside the Foreman SQLite
 * database.  The `db` instance is obtained from `ForemanStore.getDb()`.
 *
 * Thread-safety: SQLite in WAL mode with busy_timeout=30 000 ms handles
 * concurrent readers/writers; the claim() method uses a single synchronous
 * transaction so it is effectively atomic within the same process.
 */
export class NativeTaskStore {
  constructor(private readonly db: Database) {}

  /**
   * Returns true when the `tasks` table contains at least one row.
   *
   * Used by Dispatcher.getReadyTasks() as a coexistence check: if native
   * tasks exist, use the native path; otherwise fall back to BeadsRustClient.
   *
   * Also guards against the case where the schema migration has not yet run
   * by catching SQLite errors (table not found) and returning false.
   */
  hasNativeTasks(): boolean {
    try {
      const row = this.db
        .prepare("SELECT COUNT(*) as cnt FROM tasks LIMIT 1")
        .get() as { cnt: number } | undefined;
      return (row?.cnt ?? 0) > 0;
    } catch {
      // Table may not exist (migration not yet applied) — treat as empty
      return false;
    }
  }

  /**
   * List tasks from the `tasks` table.
   *
   * @param opts.status — filter by exact status value (e.g. "ready")
   */
  list(opts?: { status?: string }): Issue[] {
    let sql = "SELECT * FROM tasks";
    const params: string[] = [];

    if (opts?.status) {
      sql += " WHERE status = ?";
      params.push(opts.status);
    }

    sql += " ORDER BY priority ASC, created_at ASC";

    const rows = this.db.prepare(sql).all(...params) as TaskRow[];
    return rows.map(rowToIssue);
  }

  /**
   * Atomically claim a task: set status='in-progress' and run_id=runId
   * in a single synchronous transaction.
   *
   * Throws if the task is already claimed by a different run (concurrent
   * dispatch guard) or if the task does not exist.
   */
  claim(id: string, runId: string): void {
    const now = new Date().toISOString();

    const tx = this.db.transaction(() => {
      const row = this.db
        .prepare("SELECT id, status, run_id FROM tasks WHERE id = ?")
        .get(id) as { id: string; status: string; run_id: string | null } | undefined;

      if (!row) {
        throw new Error(`NativeTaskStore.claim: task '${id}' not found`);
      }

      // Allow re-claiming if already claimed by the same run (idempotent)
      if (row.run_id && row.run_id !== runId) {
        throw new Error(
          `NativeTaskStore.claim: task '${id}' already claimed by run '${row.run_id}'`,
        );
      }

      this.db
        .prepare(
          "UPDATE tasks SET status = 'in-progress', run_id = ?, updated_at = ? WHERE id = ?",
        )
        .run(runId, now, id);
    });

    tx();
  }

  /**
   * Update the phase of a task (used by pipeline-executor to record progress).
   * No-op when taskId is null (beads fallback mode — REQ-020).
   */
  updatePhase(taskId: string | null, phase: string): void {
    if (!taskId) return; // beads fallback — no-op

    const now = new Date().toISOString();
    this.db
      .prepare("UPDATE tasks SET status = ?, updated_at = ? WHERE id = ?")
      .run(phase, now, taskId);
  }

  /**
   * Update the status of a task.
   */
  updateStatus(taskId: string, status: string): void {
    const now = new Date().toISOString();
    this.db
      .prepare("UPDATE tasks SET status = ?, updated_at = ? WHERE id = ?")
      .run(status, now, taskId);
  }
}
