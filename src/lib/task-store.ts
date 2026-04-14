/**
 * NativeTaskStore — wraps the native `tasks` SQLite table for use as a
 * task-tracking back-end inside the Dispatcher.
 *
 * Implements methods for the full lifecycle of native tasks:
 *   - hasNativeTasks() — coexistence check (REQ-014)
 *   - list()           — query tasks with optional status filter (REQ-017)
 *   - ready()          — query dispatchable tasks: status='ready' AND run_id IS NULL (REQ-017, REQ-020)
 *   - get()            — fetch a single task row by ID
 *   - claim()          — atomically claim a task for a run (REQ-020)
 *   - updatePhase()    — update phase column (no-op when taskId is null)
 *   - updateStatus()   — update task status
 *   - create()         — create a new task in backlog status (REQ-006)
 *   - update()         — update task fields (title, description, priority, status) (REQ-007)
 *   - approve()        — transition backlog → ready (REQ-005)
 *   - close()          — mark task as closed (REQ-008)
 *   - addDependency()  — add a task dependency with cycle detection (REQ-004, REQ-021.3)
 *   - getDependencies()— retrieve dependencies in either direction
 *   - removeDependency()— remove a dependency edge
 *   - hasCyclicDependency() — DFS cycle detection
 *   - reevaluateBlockedTasks() — unblock tasks when all blockers are merged/closed
 */

import { randomUUID } from "node:crypto";
import type { Database } from "better-sqlite3";
import type { Issue } from "./task-client.js";

// ── Priority helpers ─────────────────────────────────────────────────────

const PRIORITY_ALIAS_MAP: Record<string, number> = {
  critical: 0,
  p0: 0,
  high: 1,
  p1: 1,
  medium: 2,
  p2: 2,
  low: 3,
  p3: 3,
  backlog: 4,
  p4: 4,
};

const PRIORITY_LABEL_MAP: Record<number, string> = {
  0: "critical",
  1: "high",
  2: "medium",
  3: "low",
  4: "backlog",
};

/**
 * Parse a priority string (alias or numeric) to a numeric value (0–4).
 *
 * Accepts human-readable aliases: critical (0), high (1), medium (2), low (3), backlog (4).
 * Also accepts p0-p4 and numeric strings "0"–"4".
 *
 * @throws {RangeError} If the value is not a recognised priority.
 */
export function parsePriority(value: string): number {
  const lower = value.toLowerCase().trim();
  if (lower in PRIORITY_ALIAS_MAP) return PRIORITY_ALIAS_MAP[lower]!;
  const n = parseInt(lower, 10);
  if (!isNaN(n) && n >= 0 && n <= 4) return n;
  throw new RangeError(
    `Invalid priority '${value}'. Use 0–4 or: critical, high, medium, low, backlog`,
  );
}

/**
 * Convert a numeric priority (0–4) to its human-readable label.
 * Returns the string representation for unknown values.
 */
export function priorityLabel(priority: number): string {
  return PRIORITY_LABEL_MAP[priority] ?? String(priority);
}

// ── Row types ────────────────────────────────────────────────────────────

/** A row from the `tasks` table (matches TASKS_SCHEMA columns). */
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

/** A row from the `task_dependencies` table. */
export interface DependencyRow {
  from_task_id: string;
  to_task_id: string;
  type: "blocks" | "parent-child";
}

// ── Options for task creation ────────────────────────────────────────────

export interface CreateTaskOptions {
  title: string;
  description?: string | null;
  type?: string;
  priority?: number;
  externalId?: string | null;
}

/** Options for updating an existing task. All fields are optional. */
export interface UpdateTaskOptions {
  title?: string;
  description?: string | null;
  priority?: number;
  status?: string;
  force?: boolean;
}

// ── Error classes ────────────────────────────────────────────────────────

/**
 * Thrown when a task ID is not found in the tasks table.
 */
export class TaskNotFoundError extends Error {
  constructor(public readonly taskId: string) {
    super(`Task '${taskId}' not found`);
    this.name = "TaskNotFoundError";
  }
}

/**
 * Thrown when attempting an invalid status transition.
 * (e.g. approving a task that is not in 'backlog' status)
 */
export class InvalidStatusTransitionError extends Error {
  constructor(
    public readonly taskId: string,
    public readonly fromStatus: string,
    public readonly toStatus: string,
  ) {
    super(
      `Task '${taskId}': cannot transition from '${fromStatus}' to '${toStatus}'`,
    );
    this.name = "InvalidStatusTransitionError";
  }
}

/**
 * Thrown when attempting to add a dependency that would create a cycle.
 */
export class CircularDependencyError extends Error {
  constructor(
    public readonly fromId: string,
    public readonly toId: string,
  ) {
    super(
      `Adding dependency from '${fromId}' to '${toId}' would create a circular dependency`,
    );
    this.name = "CircularDependencyError";
  }
}

// ── Helper: convert TaskRow to Issue ─────────────────────────────────────

/**
 * Convert a TaskRow to a normalized Issue (used by list()).
 * Priority is stored as INTEGER (0–4); normalise to string for Issue.
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

  // ── Existence check ───────────────────────────────────────────────────

  /**
   * Returns true when the `tasks` table contains at least one row.
   *
   * Used by Dispatcher.getReadyTasks() as a coexistence check: if native
   * tasks exist, use the native path; otherwise fall back to BeadsRustClient.
   */
  hasNativeTasks(): boolean {
    try {
      const row = this.db
        .prepare("SELECT COUNT(*) as cnt FROM tasks LIMIT 1")
        .get() as { cnt: number } | undefined;
      return (row?.cnt ?? 0) > 0;
    } catch {
      return false;
    }
  }

  // ── Query operations ──────────────────────────────────────────────────

  /**
   * List tasks from the `tasks` table, ordered by priority ASC, created_at ASC.
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
   * Return tasks that are ready to be dispatched (status='ready' and not yet claimed).
   *
   * Satisfies REQ-017 (list dispatchable tasks) and REQ-020 (claim mechanism).
   * Only returns tasks where run_id IS NULL — tasks already claimed by an active
   * run are excluded.
   *
   * Ordering: priority ASC, created_at ASC (consistent with list()).
   */
  async ready(): Promise<Issue[]> {
    const rows = this.db
      .prepare(
        `SELECT * FROM tasks
         WHERE status = 'ready' AND run_id IS NULL
         ORDER BY priority ASC, created_at ASC`,
      )
      .all() as TaskRow[];
    return rows.map(rowToIssue);
  }

  /**
   * Retrieve a single task by ID. Returns null if not found.
   */
  get(id: string): TaskRow | null {
    const row = this.db.prepare("SELECT * FROM tasks WHERE id = ?").get(id) as
      | TaskRow
      | undefined;
    return row ?? null;
  }

  /**
   * Retrieve a single task by external_id. Returns null if not found.
   *
   * Used by native sling import to provide idempotent re-runs keyed by TRD IDs.
   */
  getByExternalId(externalId: string): TaskRow | null {
    const row = this.db
      .prepare("SELECT * FROM tasks WHERE external_id = ?")
      .get(externalId) as TaskRow | undefined;
    return row ?? null;
  }

  // ── Lifecycle operations ──────────────────────────────────────────────

  /**
   * Create a new task in 'backlog' status.
   *
   * Implements REQ-006 (task creation). Tasks start in backlog and must be
   * approved before the dispatcher will pick them up (REQ-005 approval gate).
   *
   * @returns The newly created TaskRow.
   */
  create(opts: CreateTaskOptions): TaskRow {
    const now = new Date().toISOString();
    const id = randomUUID();

    this.db
      .prepare(
        `INSERT INTO tasks
           (id, title, description, type, priority, status, external_id, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, 'backlog', ?, ?, ?)`,
      )
      .run(
        id,
        opts.title,
        opts.description ?? null,
        opts.type ?? "task",
        opts.priority ?? 2,
        opts.externalId ?? null,
        now,
        now,
      );

    return this.db.prepare("SELECT * FROM tasks WHERE id = ?").get(id) as TaskRow;
  }

  /**
   * Approve a task: transition from 'backlog' → 'ready'.
   *
   * Implements REQ-005 (approval gate). Only backlog tasks can be approved.
   * After approval, the task becomes visible to the dispatcher.
   *
   * @throws {TaskNotFoundError} If the task ID does not exist.
   * @throws {InvalidStatusTransitionError} If the task is not in 'backlog' status.
   */
  approve(id: string): void {
    const now = new Date().toISOString();

    const tx = this.db.transaction(() => {
      const row = this.db
        .prepare("SELECT id, status FROM tasks WHERE id = ?")
        .get(id) as { id: string; status: string } | undefined;

      if (!row) {
        throw new TaskNotFoundError(id);
      }

      if (row.status !== "backlog") {
        throw new InvalidStatusTransitionError(id, row.status, "ready");
      }

      this.db
        .prepare(
          "UPDATE tasks SET status = 'ready', approved_at = ?, updated_at = ? WHERE id = ?",
        )
        .run(now, now, id);
    });

    tx();
  }

  /**
   * Update mutable fields on an existing task.
   *
   * Implements REQ-007 AC-007.3 (task update CLI).
   *
   * @param id    - Task ID to update.
   * @param opts  - Partial update options.
   *
   * @throws {TaskNotFoundError} If the task ID does not exist.
   * @throws {InvalidStatusTransitionError} If --force is not set and a backward
   *                                         status transition is attempted.
   */
  update(id: string, opts: UpdateTaskOptions): TaskRow {
    const now = new Date().toISOString();

    const tx = this.db.transaction(() => {
      const row = this.db
        .prepare("SELECT id, status FROM tasks WHERE id = ?")
        .get(id) as { id: string; status: string } | undefined;

      if (!row) {
        throw new TaskNotFoundError(id);
      }

      // Build dynamic UPDATE
      const sets: string[] = [];
      const values: unknown[] = [];

      if (opts.title !== undefined) {
        sets.push("title = ?");
        values.push(opts.title);
      }
      if (opts.description !== undefined) {
        sets.push("description = ?");
        values.push(opts.description);
      }
      if (opts.priority !== undefined) {
        sets.push("priority = ?");
        values.push(opts.priority);
      }
      if (opts.status !== undefined) {
        // Validate backward transitions
        if (!opts.force) {
          const statusOrder: Record<string, number> = {
            backlog: 0,
            ready: 1,
            "in-progress": 2,
            explorer: 3,
            developer: 3,
            qa: 3,
            reviewer: 3,
            finalize: 4,
            merged: 5,
            closed: 5,
            conflict: -1,
            failed: -1,
            stuck: -1,
            blocked: 0,
          };
          const fromOrder = statusOrder[row.status] ?? 0;
          const toOrder = statusOrder[opts.status] ?? 0;
          // Backward = going to a lower-order number (except conflict/failed which are terminal)
          if (toOrder >= 0 && fromOrder > toOrder) {
            throw new InvalidStatusTransitionError(id, row.status, opts.status);
          }
        }
        sets.push("status = ?");
        values.push(opts.status);
      }

      if (sets.length === 0) return row as TaskRow;

      sets.push("updated_at = ?");
      values.push(now);
      values.push(id);

      this.db.prepare(`UPDATE tasks SET ${sets.join(", ")} WHERE id = ?`).run(...values);

      return this.db.prepare("SELECT * FROM tasks WHERE id = ?").get(id) as TaskRow;
    });

    return tx();
  }

  /**
   * Close a task by setting its status to 'merged' (completed state).
   *
   * Implements REQ-008 (task closure). After closing, the task is no longer active.
   *
   * @param id     - Task ID to close.
   * @param reason - Optional reason for closing (ignored in current implementation;
   *                 could be stored in a notes field in a future iteration).
   *
   * @throws {TaskNotFoundError} If the task ID does not exist.
   */
  close(id: string, _reason?: string): void {
    const now = new Date().toISOString();

    const tx = this.db.transaction(() => {
      const row = this.db
        .prepare("SELECT id FROM tasks WHERE id = ?")
        .get(id) as { id: string } | undefined;

      if (!row) {
        throw new TaskNotFoundError(id);
      }

      this.db
        .prepare(
          "UPDATE tasks SET status = 'closed', closed_at = ?, updated_at = ? WHERE id = ?",
        )
        .run(now, now, id);
    });

    tx();
  }

  /**
   * Atomically claim a task: set status='in-progress' and run_id=runId
   * in a single synchronous transaction.
   *
   * @throws {Error} If the task does not exist.
   * @throws {Error} If the task is already claimed by a different run.
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
   * No-op when taskId is null or undefined (beads fallback mode — REQ-020).
   */
  updatePhase(taskId: string | null | undefined, phase: string): void {
    if (!taskId) return;

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

  // ── Dependency Management ─────────────────────────────────────────────

  /**
   * Add a dependency between two tasks.
   *
   * Implements REQ-004 (dependency graph). Checks for circular dependencies
   * before inserting (REQ-021.3).
   *
   * The dependency table stores: from_task_id → to_task_id, where
   * from_task_id is the BLOCKED task and to_task_id is the BLOCKER.
   *
   * @param fromId - The task that depends on (is blocked by) toId.
   * @param toId   - The task that blocks fromId.
   * @param type   - 'blocks' (affects dispatch) or 'parent-child' (organizational).
   *
   * @throws {TaskNotFoundError} If either task ID does not exist.
   * @throws {CircularDependencyError} If the dependency would create a cycle.
   */
  addDependency(fromId: string, toId: string, type: "blocks" | "parent-child" = "blocks"): void {
    const tx = this.db.transaction(() => {
      // Verify both tasks exist
      const from = this.db.prepare("SELECT id FROM tasks WHERE id = ?").get(fromId) as
        | { id: string }
        | undefined;
      if (!from) throw new TaskNotFoundError(fromId);

      const to = this.db.prepare("SELECT id FROM tasks WHERE id = ?").get(toId) as
        | { id: string }
        | undefined;
      if (!to) throw new TaskNotFoundError(toId);

      // Check for self-dependency
      if (fromId === toId) {
        throw new CircularDependencyError(fromId, toId);
      }

      // Check for cycles: would adding fromId→toId create a cycle?
      // A cycle exists if toId can already reach fromId (toId→...→fromId).
      if (this._canReach(toId, fromId)) {
        throw new CircularDependencyError(fromId, toId);
      }

      // Insert (ignore duplicates via OR IGNORE)
      this.db
        .prepare(
          `INSERT OR IGNORE INTO task_dependencies (from_task_id, to_task_id, type)
           VALUES (?, ?, ?)`,
        )
        .run(fromId, toId, type);
    });

    tx();
  }

  /**
   * Remove a dependency between two tasks. No-op if it does not exist.
   *
   * @param fromId - The dependent task.
   * @param toId   - The blocker task.
   * @param type   - Dependency type to remove.
   */
  removeDependency(
    fromId: string,
    toId: string,
    type: "blocks" | "parent-child" = "blocks",
  ): void {
    this.db
      .prepare(
        "DELETE FROM task_dependencies WHERE from_task_id = ? AND to_task_id = ? AND type = ?",
      )
      .run(fromId, toId, type);
  }

  /**
   * Get the dependencies of a task.
   *
   * @param id        - The task ID to query.
   * @param direction - 'outgoing' (tasks this task depends on) | 'incoming' (tasks that depend on this).
   */
  getDependencies(
    id: string,
    direction: "outgoing" | "incoming" = "outgoing",
  ): DependencyRow[] {
    if (direction === "outgoing") {
      return this.db
        .prepare("SELECT * FROM task_dependencies WHERE from_task_id = ?")
        .all(id) as DependencyRow[];
    } else {
      return this.db
        .prepare("SELECT * FROM task_dependencies WHERE to_task_id = ?")
        .all(id) as DependencyRow[];
    }
  }

  /**
   * Check whether adding a new fromId→toId dependency would create a cycle.
   *
   * Returns true if toId can already reach fromId (which would create a cycle).
   * Uses DFS via existing dependency edges.
   */
  hasCyclicDependency(fromId: string, toId: string): boolean {
    // "Would adding fromId→toId create a cycle?"
    // Yes, if toId can already reach fromId via existing edges.
    return this._canReach(toId, fromId);
  }

  /**
   * Internal DFS: returns true if `target` is reachable from `start`
   * via outgoing edges in the task_dependencies table.
   */
  private _canReach(start: string, target: string): boolean {
    const visited = new Set<string>();
    const queue: string[] = [start];

    while (queue.length > 0) {
      const current = queue.pop()!;
      if (current === target) return true;
      if (visited.has(current)) continue;
      visited.add(current);

      const deps = this.db
        .prepare("SELECT to_task_id FROM task_dependencies WHERE from_task_id = ?")
        .all(current) as Array<{ to_task_id: string }>;

      for (const dep of deps) {
        queue.push(dep.to_task_id);
      }
    }

    return false;
  }

  // ── Bulk Operations ───────────────────────────────────────────────────

  /**
   * Re-evaluate tasks in 'blocked' status and transition them to 'ready'
   * if all their blocking dependencies have been completed (status IN ('merged', 'closed')).
   *
   * The dependency table stores from_task_id (BLOCKED) → to_task_id (BLOCKER).
   * So unresolved blockers = rows WHERE from_task_id = <blocked_task>
   *   AND type = 'blocks' AND blocker.status NOT IN ('merged', 'closed').
   */
  reevaluateBlockedTasks(): void {
    const now = new Date().toISOString();

    const blockedTasks = this.db
      .prepare("SELECT id FROM tasks WHERE status = 'blocked'")
      .all() as Array<{ id: string }>;

    for (const task of blockedTasks) {
      const unresolvedCount = this.db
        .prepare(
          `SELECT COUNT(*) as cnt
           FROM task_dependencies td
           JOIN tasks blocker ON blocker.id = td.to_task_id
           WHERE td.from_task_id = ?
             AND td.type = 'blocks'
             AND blocker.status NOT IN ('merged', 'closed')`,
        )
        .get(task.id) as { cnt: number } | undefined;

      if ((unresolvedCount?.cnt ?? 0) === 0) {
        // Transition to 'ready' and set approved_at so the task is treated as approved
        // (matches the semantics of approve() which sets approved_at when → ready)
        this.db
          .prepare("UPDATE tasks SET status = 'ready', approved_at = COALESCE(approved_at, ?), updated_at = ? WHERE id = ?")
          .run(now, now, task.id);
      }
    }
  }
}
