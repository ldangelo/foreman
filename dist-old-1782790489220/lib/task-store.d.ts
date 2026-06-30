/**
 * NativeTaskStore — legacy task table adapter retained for compatibility.
 * New task storage is Postgres-backed via the daemon.
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
import type { Issue } from "./task-client.js";
import type { NativeTaskStatus } from "../orchestrator/types.js";
type Database = {
    prepare: (sql: string) => {
        run: (...args: unknown[]) => any;
        get: (...args: unknown[]) => any;
        all: (...args: unknown[]) => any[];
    };
    transaction: (fn: (...args: unknown[]) => unknown) => (...args: unknown[]) => any;
};
export interface NativeTaskStoreOptions {
    projectKey?: string;
    autoMigrateLegacyIds?: boolean;
}
export interface TaskIdMigrationResult {
    migrated: number;
    deferredActive: number;
}
export declare function normalizeTaskIdPrefix(raw: string | null | undefined): string;
export declare function isLegacyUuidTaskId(taskId: string): boolean;
export declare function isCompactTaskId(taskId: string): boolean;
export declare function formatTaskIdDisplay(taskId: string): string;
/**
 * Parse a priority string (alias or numeric) to a numeric value (0–4).
 *
 * Accepts human-readable aliases: critical (0), high (1), medium (2), low (3), backlog (4).
 * Also accepts p0-p4 and numeric strings "0"–"4".
 *
 * @throws {RangeError} If the value is not a recognised priority.
 */
export declare function parsePriority(value: string): number;
/**
 * Convert a numeric priority (0–4) to its human-readable label.
 * Returns the string representation for unknown values.
 */
export declare function priorityLabel(priority: number): string;
/** A row from the `tasks` table (matches TASKS_SCHEMA columns). */
export interface TaskRow {
    id: string;
    title: string;
    description: string | null;
    type: string;
    priority: number;
    status: NativeTaskStatus;
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
    status?: NativeTaskStatus;
    force?: boolean;
}
/**
 * Thrown when a task ID is not found in the tasks table.
 */
export declare class TaskNotFoundError extends Error {
    readonly taskId: string;
    constructor(taskId: string);
}
/**
 * Thrown when attempting an invalid status transition.
 * (e.g. approving a task that is not in 'backlog' status)
 */
export declare class InvalidStatusTransitionError extends Error {
    readonly taskId: string;
    readonly fromStatus: string;
    readonly toStatus: string;
    constructor(taskId: string, fromStatus: string, toStatus: string);
}
/**
 * Thrown when attempting to add a dependency that would create a cycle.
 */
export declare class CircularDependencyError extends Error {
    readonly fromId: string;
    readonly toId: string;
    constructor(fromId: string, toId: string);
}
/**
 * Provides read/write access to the `tasks` table inside the Foreman Postgres
 * database.  The `db` instance is obtained from `ForemanStore.getDb()`.
 *
 * Thread-safety: Postgres in WAL mode with busy_timeout=30 000 ms handles
 * concurrent readers/writers; the claim() method uses a single synchronous
 * transaction so it is effectively atomic within the same process.
 */
export declare class NativeTaskStore {
    private readonly db;
    private readonly explicitProjectKey;
    private cachedTaskIdPrefix;
    constructor(db: Database, opts?: NativeTaskStoreOptions);
    private canRunMigrations;
    private tableExists;
    private columnExists;
    private resolveTaskIdPrefix;
    private generateTaskId;
    allocateTaskId(): string;
    resolveTaskId(taskIdOrPrefix: string): string;
    migrateLegacyTaskIds(): TaskIdMigrationResult;
    /**
     * Returns true when the `tasks` table contains at least one row.
     *
     * Used by Dispatcher.getReadyTasks() as a coexistence check: if native
     * tasks exist, use the native path; otherwise fall back to BeadsRustClient.
     */
    hasNativeTasks(): boolean;
    /**
     * List tasks from the `tasks` table, ordered by priority ASC, created_at ASC.
     *
     * @param opts.status — filter by exact status value (e.g. "ready")
     * @param opts.type — filter by exact type value (e.g. "epic", "bug")
     */
    list(opts?: {
        status?: string;
        type?: string;
    }): Issue[];
    /**
     * Return tasks that are ready to be dispatched (status='ready' and not yet claimed).
     *
     * Satisfies REQ-017 (list dispatchable tasks) and REQ-020 (claim mechanism).
     * Only returns tasks where run_id IS NULL — tasks already claimed by an active
     * run are excluded.
     *
     * Ordering: priority ASC, created_at ASC (consistent with list()).
     */
    ready(): Promise<Issue[]>;
    /**
     * Retrieve a single task by ID. Returns null if not found.
     */
    get(id: string): TaskRow | null;
    /**
     * Retrieve a single task by external_id. Returns null if not found.
     *
     * Used by native sling import to provide idempotent re-runs keyed by TRD IDs.
     */
    getByExternalId(externalId: string): TaskRow | null;
    /**
     * Create a new task in 'backlog' status.
     *
     * Implements REQ-006 (task creation). Tasks start in backlog and must be
     * approved before the dispatcher will pick them up (REQ-005 approval gate).
     *
     * @returns The newly created TaskRow.
     */
    create(opts: CreateTaskOptions): TaskRow;
    /**
     * Approve a task: transition from 'backlog' → 'ready'.
     *
     * Implements REQ-005 (approval gate). Only backlog tasks can be approved.
     * After approval, the task becomes visible to the dispatcher.
     *
     * @throws {TaskNotFoundError} If the task ID does not exist.
     * @throws {InvalidStatusTransitionError} If the task is not in 'backlog' status.
     */
    approve(id: string): void;
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
    update(id: string, opts: UpdateTaskOptions): TaskRow;
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
    close(id: string, _reason?: string): void;
    /**
     * Reset a task back to the ready queue for retry.
     *
     * Operator-only path used by `foreman reset`. Unlike `update({status:"ready"})`,
     * this intentionally allows backward recovery from active execution states and
     * clears any existing run linkage so the dispatcher can claim the task again.
     *
     * Closed / merged tasks are not reopened by this method.
     *
     * @throws {TaskNotFoundError} If the task does not exist.
     * @throws {InvalidStatusTransitionError} If the task is already terminal.
     */
    resetToReady(id: string, _reason?: string): TaskRow;
    /**
     * Atomically claim a task: set status='in-progress' and run_id=runId
     * in a single synchronous transaction.
     *
     * @throws {Error} If the task does not exist.
     * @throws {Error} If the task is already claimed by a different run.
     */
    claim(id: string, runId: string): void;
    /**
     * Update the phase of a task (used by pipeline-executor to record progress).
     * No-op when taskId is null or undefined.
     */
    updatePhase(taskId: string | null | undefined, phase: string): void;
    /**
     * Update the status of a task.
     */
    updateStatus(taskId: string, status: string): void;
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
    addDependency(fromId: string, toId: string, type?: "blocks" | "parent-child"): void;
    /**
     * Remove a dependency between two tasks. No-op if it does not exist.
     *
     * @param fromId - The dependent task.
     * @param toId   - The blocker task.
     * @param type   - Dependency type to remove.
     */
    removeDependency(fromId: string, toId: string, type?: "blocks" | "parent-child"): void;
    /**
     * Get the dependencies of a task.
     *
     * @param id        - The task ID to query.
     * @param direction - 'outgoing' (tasks this task depends on) | 'incoming' (tasks that depend on this).
     */
    getDependencies(id: string, direction?: "outgoing" | "incoming"): DependencyRow[];
    /**
     * Check whether adding a new fromId→toId dependency would create a cycle.
     *
     * Returns true if toId can already reach fromId (which would create a cycle).
     * Uses DFS via existing dependency edges.
     */
    hasCyclicDependency(fromId: string, toId: string): boolean;
    /**
     * Internal DFS: returns true if `target` is reachable from `start`
     * via outgoing edges in the task_dependencies table.
     */
    private _canReach;
    /**
     * Re-evaluate tasks in 'blocked' status and transition them to 'ready'
     * if all their blocking dependencies have been completed (status IN ('merged', 'closed')).
     *
     * The dependency table stores from_task_id (BLOCKED) → to_task_id (BLOCKER).
     * So unresolved blockers = rows WHERE from_task_id = <blocked_task>
     *   AND type = 'blocks' AND blocker.status NOT IN ('merged', 'closed').
     */
    reevaluateBlockedTasks(): void;
}
export {};
//# sourceMappingURL=task-store.d.ts.map