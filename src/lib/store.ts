import Database from "better-sqlite3";
import { mkdirSync, existsSync, realpathSync } from "node:fs";
import { join, dirname, resolve as resolvePath } from "node:path";
import { homedir } from "node:os";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";

/**
 * Resolve the path to the better-sqlite3 native addon when running from a
 * bundled context (i.e. `dist/foreman-bundle.js`).
 *
 * During development / `npm run build`, the addon is resolved by the bindings
 * module via node_modules, so no special handling is needed. But when the CLI
 * is run as a standalone bundle (esbuild output), node_modules may not exist,
 * so we look for `better_sqlite3.node` placed alongside the bundle by the
 * postbundle copy step in scripts/bundle.ts.
 *
 * @returns Absolute path to better_sqlite3.node, or undefined (use default loader).
 */
function resolveBundledNativeBinding(): string | undefined {
  try {
    // import.meta.url is available in ESM. In a bundled context this resolves
    // to the bundle file's path (e.g. /path/to/dist/foreman-bundle.js).
    const selfDir = dirname(fileURLToPath(import.meta.url));
    const candidate = join(selfDir, "better_sqlite3.node");
    if (existsSync(candidate)) {
      return candidate;
    }
  } catch {
    // Swallow — fileURLToPath / import.meta.url unavailable in some edge cases
  }
  return undefined;
}

function normalizeProjectPath(path: string): string {
  const resolved = resolvePath(path);
  if (!existsSync(resolved)) {
    return resolved;
  }

  try {
    return realpathSync.native?.(resolved) ?? realpathSync(resolved);
  } catch {
    return resolved;
  }
}

// ── Interfaces ──────────────────────────────────────────────────────────

export interface Project {
  id: string;
  name: string;
  path: string;
  status: "active" | "paused" | "archived";
  created_at: string;
  updated_at: string;
}

export interface Run {
  id: string;
  project_id: string;
  seed_id: string;
  agent_type: string;
  session_key: string | null;
  worktree_path: string | null;
  status: "pending" | "running" | "completed" | "failed" | "stuck" | "merged" | "conflict" | "test-failed" | "pr-created" | "reset";
  started_at: string | null;
  completed_at: string | null;
  created_at: string;
  progress: string | null;
  /** @deprecated tmux removed; column kept for DB backward compat */
  tmux_session?: string | null;
  /** Branch that this seed's worktree was branched from (null = default branch). Used for branch stacking. */
  base_branch?: string | null;
  /** Per-run merge strategy: 'auto' (refinery), 'pr' (gh pr create), or 'none' (skip). */
  merge_strategy?: "auto" | "pr" | "none" | null;
}

export interface Cost {
  id: string;
  run_id: string;
  tokens_in: number;
  tokens_out: number;
  cache_read: number;
  estimated_cost: number;
  recorded_at: string;
}

export type EventType =
  | "dispatch"
  | "claim"
  | "complete"
  | "fail"
  | "merge"
  | "stuck"
  | "restart"
  | "recover"
  | "conflict"
  | "test-fail"
  | "pr-created"
  | "merge-queue-enqueue"
  | "merge-queue-dequeue"
  | "merge-queue-resolve"
  | "merge-queue-fallback"
  | "sentinel-start"
  | "sentinel-pass"
  | "sentinel-fail";

export interface Event {
  id: string;
  project_id: string;
  run_id: string | null;
  event_type: EventType;
  details: string | null;
  created_at: string;
}

export interface RunProgress {
  toolCalls: number;
  toolBreakdown: Record<string, number>; // e.g. { Read: 12, Edit: 5, Bash: 3 }
  filesChanged: string[];
  turns: number;
  costUsd: number;
  tokensIn: number;
  tokensOut: number;
  lastToolCall: string | null;  // most recent tool name
  lastActivity: string;         // ISO timestamp
  currentPhase?: string;        // Pipeline phase: "explorer" | "developer" | "qa" | "reviewer" | "finalize"
  costByPhase?: Record<string, number>;  // e.g. { explorer: 0.10, developer: 0.50 }
  agentByPhase?: Record<string, string>; // e.g. { explorer: "claude-haiku-4-5", developer: "claude-sonnet-4-6" }
  /** Target branch name QA validated against. */
  qaValidatedTargetBranch?: string;
  /** Target branch revision/hash resolved when QA passed. */
  qaValidatedTargetRef?: string;
  /** Workspace HEAD revision/hash resolved when QA passed. */
  qaValidatedHeadRef?: string;
  /** Current target branch revision/hash resolved during finalize preparation. */
  currentTargetRef?: string;
  /** Epic mode: total number of child tasks. */
  epicTaskCount?: number;
  /** Epic mode: number of tasks completed so far. */
  epicTasksCompleted?: number;
  /** Epic mode: seed ID of the currently executing task. */
  epicCurrentTaskId?: string;
  /** Epic mode: per-task cost breakdown. */
  epicCostByTask?: Record<string, number>;
}

export interface Metrics {
  totalCost: number;
  totalTokens: number;
  tasksByStatus: Record<string, number>;
  costByRuntime: Array<{ run_id: string; cost: number; duration_seconds: number | null }>;
  costByPhase?: Record<string, number>;      // aggregated cost per pipeline phase
  agentCostBreakdown?: Record<string, number>; // aggregated cost per model/agent type
}

// ── Messaging interfaces ─────────────────────────────────────────────────

export interface Message {
  id: string;
  run_id: string;
  sender_agent_type: string;
  recipient_agent_type: string;
  subject: string;
  body: string;
  read: number; // 0 = unread, 1 = read (SQLite boolean)
  created_at: string;
  deleted_at: string | null;
}

/**
 * Represents a pending bead write operation in the serialized write queue.
 *
 * Operations are inserted by agent-workers, refinery, pipeline-executor, and
 * auto-merge, then drained and executed sequentially by the dispatcher.
 * This eliminates concurrent br CLI invocations that cause SQLite contention.
 */
export interface BeadWriteEntry {
  /** Unique entry ID (UUID). */
  id: string;
  /** Source of the write (e.g. "agent-worker", "refinery", "pipeline-executor"). */
  sender: string;
  /** Operation type: "close-seed" | "reset-seed" | "mark-failed" | "add-notes" | "add-labels". */
  operation: string;
  /** JSON-encoded payload specific to the operation. */
  payload: string;
  /** ISO timestamp when the entry was inserted. */
  created_at: string;
  /** ISO timestamp when the entry was processed (null = pending). */
  processed_at: string | null;
}

// ── Native Task interfaces ───────────────────────────────────────────────

/**
 * A task row from the native SQLite `tasks` table (PRD-2026-006 REQ-003).
 * Matches the TASKS_SCHEMA column definitions.
 */
export interface NativeTask {
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

// ── Merge Agent interfaces ───────────────────────────────────────────────

export interface MergeAgentConfigRow {
  id: string;
  enabled: number; // 0 or 1
  poll_interval_ms: number;
  created_at: string;
  updated_at: string;
}

// ── Sentinel interfaces ──────────────────────────────────────────────────

export interface SentinelConfigRow {
  id: number;
  project_id: string;
  branch: string;
  test_command: string;
  interval_minutes: number;
  failure_threshold: number;
  enabled: number; // 0 or 1
  pid: number | null;
  created_at: string;
  updated_at: string;
}

export interface SentinelRunRow {
  id: string;
  project_id: string;
  branch: string;
  commit_hash: string | null;
  status: "running" | "passed" | "failed" | "error";
  test_command: string;
  output: string | null;
  failure_count: number;
  started_at: string;
  completed_at: string | null;
}

// ── Native Task interface ────────────────────────────────────────────────

/**
 * A task row from the native `tasks` table (PRD-2026-006 REQ-003).
 * Used by the dashboard "Needs Human" panel and phase-visibility views.
 */
export interface NativeTask {
  id: string;
  title: string;
  description: string | null;
  type: string;
  priority: number;   // 0=P0 (critical) … 4=P4 (backlog)
  status: string;
  run_id: string | null;
  branch: string | null;
  external_id: string | null;
  created_at: string;
  updated_at: string;
  approved_at: string | null;
  closed_at: string | null;
  /** Attached project name/id for cross-project aggregation (not a DB column). */
  projectName?: string;
  projectId?: string;
  projectPath?: string;
}

// ── Error classes ───────────────────────────────────────────────────────

/**
 * Thrown when a task status value is not in the set of valid statuses defined
 * by the tasks table CHECK constraint.
 *
 * Valid statuses mirror the CHECK constraint in TASKS_SCHEMA below.
 * Update both if new statuses are added (ref: PRD-2026-006 REQ-003).
 */
export class InvalidTaskStatusError extends Error {
  constructor(
    public readonly attemptedStatus: string,
    public readonly validStatuses: string[],
  ) {
    super(
      `Invalid task status '${attemptedStatus}'. Valid statuses: ${validStatuses.join(", ")}`,
    );
    this.name = "InvalidTaskStatusError";
  }
}

// ── Schema migration ────────────────────────────────────────────────────

const SCHEMA = `
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
  FOREIGN KEY (project_id) REFERENCES projects(id)
);

CREATE TABLE IF NOT EXISTS costs (
  id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL,
  tokens_in INTEGER DEFAULT 0,
  tokens_out INTEGER DEFAULT 0,
  cache_read INTEGER DEFAULT 0,
  estimated_cost REAL DEFAULT 0.0,
  recorded_at TEXT,
  FOREIGN KEY (run_id) REFERENCES runs(id)
);

CREATE TABLE IF NOT EXISTS events (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  run_id TEXT,
  event_type TEXT NOT NULL,
  details TEXT,
  created_at TEXT,
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

CREATE TABLE IF NOT EXISTS conflict_patterns (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  file_path TEXT NOT NULL,
  file_extension TEXT NOT NULL,
  tier INTEGER NOT NULL,
  success INTEGER NOT NULL,
  failure_reason TEXT,
  merge_queue_id INTEGER,
  seed_id TEXT,
  recorded_at TEXT NOT NULL,
  FOREIGN KEY (merge_queue_id) REFERENCES merge_queue(id)
);

CREATE INDEX IF NOT EXISTS idx_conflict_patterns_file ON conflict_patterns (file_extension, tier);
CREATE INDEX IF NOT EXISTS idx_conflict_patterns_merge ON conflict_patterns (merge_queue_id);

CREATE TABLE IF NOT EXISTS merge_costs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL,
  merge_queue_id INTEGER,
  file_path TEXT NOT NULL,
  tier INTEGER NOT NULL,
  model TEXT NOT NULL,
  input_tokens INTEGER NOT NULL,
  output_tokens INTEGER NOT NULL,
  estimated_cost_usd REAL NOT NULL,
  actual_cost_usd REAL NOT NULL,
  recorded_at TEXT NOT NULL,
  FOREIGN KEY (merge_queue_id) REFERENCES merge_queue(id)
);

CREATE INDEX IF NOT EXISTS idx_merge_costs_session ON merge_costs (session_id);
CREATE INDEX IF NOT EXISTS idx_merge_costs_date ON merge_costs (recorded_at);

`;

// Bead write queue DDL — project-scoped serialized write queue for br operations.
// Agent-workers, refinery, pipeline-executor, and auto-merge enqueue writes here.
// The dispatcher drains this table sequentially, executing br CLI commands one at a
// time, eliminating concurrent SQLite lock contention on .beads/beads.jsonl.
const BEAD_WRITE_QUEUE_SCHEMA = `
CREATE TABLE IF NOT EXISTS bead_write_queue (
  id TEXT PRIMARY KEY,
  sender TEXT NOT NULL,
  operation TEXT NOT NULL,
  payload TEXT NOT NULL,
  created_at TEXT NOT NULL,
  processed_at TEXT DEFAULT NULL
);

CREATE INDEX IF NOT EXISTS idx_bead_write_queue_pending
  ON bead_write_queue (processed_at, created_at);
`;

// Messages table DDL — kept separate so it can be applied after pre-flight migrations
// that drop any incompatible legacy messages table.
const MESSAGES_SCHEMA = `
CREATE TABLE IF NOT EXISTS messages (
  id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL,
  sender_agent_type TEXT NOT NULL,
  recipient_agent_type TEXT NOT NULL,
  subject TEXT NOT NULL,
  body TEXT NOT NULL,
  read INTEGER DEFAULT 0,
  created_at TEXT NOT NULL,
  deleted_at TEXT DEFAULT NULL,
  FOREIGN KEY (run_id) REFERENCES runs(id)
);

CREATE INDEX IF NOT EXISTS idx_messages_run_recipient
  ON messages (run_id, recipient_agent_type);

CREATE INDEX IF NOT EXISTS idx_messages_run_sender
  ON messages (run_id, sender_agent_type);
`;

// Tasks table DDL — native task management (PRD-2026-006 REQ-003).
// Stores tasks created by `foreman task create` or imported from beads.
// All valid statuses are enumerated in the CHECK constraint; update
// InvalidTaskStatusError.VALID_STATUSES if this list changes.
const TASKS_SCHEMA = `
CREATE TABLE IF NOT EXISTS tasks (
  id          TEXT PRIMARY KEY,
  title       TEXT NOT NULL,
  description TEXT,
  type        TEXT NOT NULL DEFAULT 'task',
  priority    INTEGER NOT NULL DEFAULT 2,
  status      TEXT NOT NULL DEFAULT 'backlog',
  run_id      TEXT REFERENCES runs(id),
  branch      TEXT,
  external_id TEXT UNIQUE,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL,
  approved_at TEXT,
  closed_at   TEXT,
  CHECK (status IN (
    'backlog', 'ready', 'in-progress',
    'explorer', 'developer', 'qa', 'reviewer', 'finalize',
    'merged', 'closed', 'conflict', 'failed', 'stuck', 'blocked'
  ))
);

CREATE INDEX IF NOT EXISTS idx_tasks_status     ON tasks (status);
CREATE INDEX IF NOT EXISTS idx_tasks_run_id     ON tasks (run_id);
CREATE INDEX IF NOT EXISTS idx_tasks_created_at ON tasks (created_at);
`;

// Task dependencies table DDL — DAG edges for task blocking (PRD-2026-006 REQ-004).
// from_task_id blocks to_task_id when type='blocks';
// parent-child expresses hierarchical decomposition.
const TASK_DEPENDENCIES_SCHEMA = `
CREATE TABLE IF NOT EXISTS task_dependencies (
  from_task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  to_task_id   TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  type         TEXT NOT NULL DEFAULT 'blocks',
  PRIMARY KEY (from_task_id, to_task_id, type),
  CHECK (type IN ('blocks', 'parent-child'))
);

CREATE INDEX IF NOT EXISTS idx_task_dependencies_to_task
  ON task_dependencies (to_task_id);
`;

// Rate limit events table for tracking per-model rate limits (P2 recommendation)
const RATE_LIMIT_EVENTS_SCHEMA = `
CREATE TABLE IF NOT EXISTS rate_limit_events (
  id          TEXT PRIMARY KEY,
  project_id  TEXT NOT NULL,
  run_id      TEXT,
  model       TEXT NOT NULL,
  phase       TEXT,
  error       TEXT NOT NULL,
  retry_after_seconds INTEGER,
  recorded_at TEXT NOT NULL,
  FOREIGN KEY (project_id) REFERENCES projects(id)
);

CREATE INDEX IF NOT EXISTS idx_rate_limit_events_model
  ON rate_limit_events (model, recorded_at DESC);

CREATE INDEX IF NOT EXISTS idx_rate_limit_events_project
  ON rate_limit_events (project_id, recorded_at DESC);
`;

// Add progress column to runs table if not present (migration)
// These migrations are idempotent via failure: ALTER TABLE and RENAME COLUMN throw
// if the change was already applied, which is caught and silently ignored.
const MIGRATIONS = [
  `ALTER TABLE runs ADD COLUMN progress TEXT DEFAULT NULL`,
  `ALTER TABLE runs RENAME COLUMN bead_id TO seed_id`,
  `ALTER TABLE runs ADD COLUMN tmux_session TEXT DEFAULT NULL`,
  `ALTER TABLE runs ADD COLUMN merge_strategy TEXT DEFAULT 'auto'`,
  `CREATE TABLE IF NOT EXISTS sentinel_configs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id TEXT NOT NULL UNIQUE,
    branch TEXT DEFAULT 'main',
    test_command TEXT DEFAULT 'npm test',
    interval_minutes INTEGER DEFAULT 30,
    failure_threshold INTEGER DEFAULT 2,
    enabled INTEGER DEFAULT 1,
    pid INTEGER DEFAULT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY (project_id) REFERENCES projects(id)
  )`,
  `CREATE TABLE IF NOT EXISTS sentinel_runs (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    branch TEXT NOT NULL,
    commit_hash TEXT,
    status TEXT DEFAULT 'running'
      CHECK (status IN ('running', 'passed', 'failed', 'error')),
    test_command TEXT NOT NULL,
    output TEXT,
    failure_count INTEGER DEFAULT 0,
    started_at TEXT NOT NULL,
    completed_at TEXT,
    FOREIGN KEY (project_id) REFERENCES projects(id)
  )`,
  `CREATE INDEX IF NOT EXISTS idx_sentinel_runs_project ON sentinel_runs (project_id, started_at DESC)`,
  `ALTER TABLE merge_queue ADD COLUMN retry_count INTEGER DEFAULT 0`,
  `ALTER TABLE merge_queue ADD COLUMN last_attempted_at TEXT DEFAULT NULL`,
  `CREATE TABLE IF NOT EXISTS merge_agent_config (
    id TEXT PRIMARY KEY DEFAULT 'default',
    enabled INTEGER NOT NULL DEFAULT 1,
    poll_interval_ms INTEGER NOT NULL DEFAULT 30000,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  )`,
  `ALTER TABLE runs ADD COLUMN base_branch TEXT DEFAULT NULL`,
  // Rate limit events table migration (P2: per-model rate limit tracking)
  `CREATE TABLE IF NOT EXISTS rate_limit_events (
    id          TEXT PRIMARY KEY,
    project_id  TEXT NOT NULL,
    run_id      TEXT,
    model       TEXT NOT NULL,
    phase       TEXT,
    error       TEXT NOT NULL,
    retry_after_seconds INTEGER,
    recorded_at TEXT NOT NULL,
    FOREIGN KEY (project_id) REFERENCES projects(id)
  )`,
  `CREATE INDEX IF NOT EXISTS idx_rate_limit_events_model
    ON rate_limit_events (model, recorded_at DESC)`,
  `CREATE INDEX IF NOT EXISTS idx_rate_limit_events_project
    ON rate_limit_events (project_id, recorded_at DESC)`,
];

// One-time destructive migrations that cannot be made idempotent via failure
// (e.g. DROP TABLE IF EXISTS never throws).  These are gated by user_version so
// they only execute once — the first time a store is opened against a legacy DB.
//
// user_version 0 → initial / legacy state (may have an old messages table)
// user_version 1 → legacy messages table + stale index have been cleaned up
const SCHEMA_VERSION = 1;

// SQL run when user_version < SCHEMA_VERSION to migrate a legacy database
const SCHEMA_UPGRADE_SQL = `
DROP TABLE IF EXISTS messages;
DROP INDEX IF EXISTS idx_messages_run_status;
`;

// ── Store ───────────────────────────────────────────────────────────────

export class ForemanStore {
  private db: Database.Database;

  /**
   * Create a ForemanStore backed by a project-local SQLite database.
   *
   * The database is stored at `<projectPath>/.foreman/foreman.db`, keeping
   * all state scoped to the project rather than the user's home directory.
   *
   * @param projectPath - Absolute path to the project root directory.
   */
  static forProject(projectPath: string): ForemanStore {
    return new ForemanStore(join(projectPath, ".foreman", "foreman.db"));
  }

  /**
   * Open the project database in READONLY mode for safe concurrent dashboard reads.
   *
   * Returns a raw better-sqlite3 `Database` instance opened with `{ readonly: true }`.
   * The caller is responsible for calling `.close()` when done.
   *
   * This is intentionally a static factory that bypasses the normal ForemanStore
   * constructor (which runs migrations and writes to the DB) — the dashboard reads
   * should never write to a project's database.
   *
   * @param projectPath - Absolute path to the project root directory.
   * @returns A readonly better-sqlite3 Database (throws if DB does not exist).
   */
  static openReadonly(projectPath: string): Database.Database {
    const dbPath = join(projectPath, ".foreman", "foreman.db");
    const nativeBinding = resolveBundledNativeBinding();
    const db = nativeBinding
      ? new Database(dbPath, { readonly: true, nativeBinding })
      : new Database(dbPath, { readonly: true });
    return db;
  }

  constructor(dbPath?: string) {
    const resolvedPath = dbPath ?? join(homedir(), ".foreman", "foreman.db");
    mkdirSync(join(resolvedPath, ".."), { recursive: true });

    // When running from a bundle (dist/foreman-bundle.js), use the native
    // addon copied by the postbundle step rather than relying on node_modules.
    const nativeBinding = resolveBundledNativeBinding();
    this.db = nativeBinding
      ? new Database(resolvedPath, { nativeBinding })
      : new Database(resolvedPath);
    this.db.pragma("journal_mode = WAL");
    this.db.pragma("foreign_keys = ON");
    this.db.pragma("busy_timeout = 30000");
    this.db.exec(SCHEMA);

    // Run idempotent migrations (errors are silently ignored — they indicate
    // the change was already applied, e.g. column already exists).
    for (const sql of MIGRATIONS) {
      try {
        this.db.exec(sql);
      } catch {
        // Column/table already exists — safe to ignore
      }
    }

    // Run one-time destructive migrations gated by user_version pragma.
    // This ensures DROP TABLE / DROP INDEX only executes once, even though
    // those statements never throw (unlike ALTER TABLE idempotency above).
    const currentVersion = this.db.pragma("user_version", { simple: true }) as number;
    if (currentVersion < SCHEMA_VERSION) {
      this.db.exec(SCHEMA_UPGRADE_SQL);
      this.db.pragma(`user_version = ${SCHEMA_VERSION}`);
    }

    // Apply messaging schema after migrations so any legacy messages table has
    // been dropped first, allowing a clean re-creation.
    this.db.exec(MESSAGES_SCHEMA);

    // Apply bead write queue schema. Uses CREATE TABLE IF NOT EXISTS so it is
    // safe to apply on every startup for both new and existing databases.
    this.db.exec(BEAD_WRITE_QUEUE_SCHEMA);

    // Apply native task management schemas (PRD-2026-006 REQ-003, REQ-004).
    // Both use CREATE TABLE IF NOT EXISTS — safe to run on every startup.
    this.db.exec(TASKS_SCHEMA);
    this.db.exec(TASK_DEPENDENCIES_SCHEMA);

    // Apply rate limit events schema (P2: per-model rate limit tracking).
    // Uses CREATE TABLE IF NOT EXISTS — safe to run on every startup.
    this.db.exec(RATE_LIMIT_EVENTS_SCHEMA);
  }

  /** Expose the underlying database for modules that need direct access (e.g. MergeQueue). */
  getDb(): Database.Database {
    return this.db;
  }

  close(): void {
    this.db.close();
  }

  // ── Native Tasks ─────────────────────────────────────────────────────

  /**
   * List tasks from the native `tasks` table filtered by one or more statuses.
   * Returns an empty array if the `tasks` table does not exist (older DBs).
   *
   * @param statuses - Array of status strings to filter by (e.g. ['conflict', 'failed', 'stuck', 'backlog'])
   * @param limit    - Maximum number of rows to return (default: 200)
   */
  listTasksByStatus(statuses: string[], limit = 200): NativeTask[] {
    if (statuses.length === 0) return [];
    try {
      const placeholders = statuses.map(() => "?").join(", ");
      return this.db
        .prepare(
          `SELECT * FROM tasks WHERE status IN (${placeholders})
           ORDER BY priority ASC, updated_at ASC
           LIMIT ?`
        )
        .all(...statuses, limit) as NativeTask[];
    } catch {
      // tasks table may not exist on older project databases
      return [];
    }
  }

  /**
   * Update a task status via a short-lived write.  Used by dashboard
   * interactive actions (approve / retry).
   *
   * @param taskId    - Task UUID to update.
   * @param newStatus - Target status (must be in TASKS_SCHEMA CHECK constraint).
   */
  updateTaskStatus(taskId: string, newStatus: string): void {
    const now = new Date().toISOString();
    this.db
      .prepare(`UPDATE tasks SET status = ?, updated_at = ? WHERE id = ?`)
      .run(newStatus, now, taskId);
  }

  // ── Projects ────────────────────────────────────────────────────────

  registerProject(name: string, path: string): Project {
    const now = new Date().toISOString();
    const normalizedPath = normalizeProjectPath(path);
    const project: Project = {
      id: randomUUID(),
      name,
      path: normalizedPath,
      status: "active",
      created_at: now,
      updated_at: now,
    };
    this.db
      .prepare(
        `INSERT INTO projects (id, name, path, status, created_at, updated_at)
         VALUES (@id, @name, @path, @status, @created_at, @updated_at)`
      )
      .run(project);
    return project;
  }

  getProject(id: string): Project | null {
    return (
      (this.db.prepare("SELECT * FROM projects WHERE id = ?").get(id) as Project | undefined) ??
      null
    );
  }

  getProjectByPath(path: string): Project | null {
    const normalizedPath = normalizeProjectPath(path);
    return (
      (this.db
        .prepare("SELECT * FROM projects WHERE path = ?")
        .get(normalizedPath) as Project | undefined) ?? null
    );
  }

  listProjects(status?: string): Project[] {
    if (status) {
      return this.db
        .prepare("SELECT * FROM projects WHERE status = ? ORDER BY created_at DESC")
        .all(status) as Project[];
    }
    return this.db
      .prepare("SELECT * FROM projects ORDER BY created_at DESC")
      .all() as Project[];
  }

  updateProject(id: string, updates: Partial<Pick<Project, "name" | "path" | "status">>): void {
    const fields: string[] = [];
    const values: Record<string, unknown> = { id };
    for (const [key, value] of Object.entries(updates)) {
      if (value !== undefined) {
        fields.push(`${key} = @${key}`);
        values[key] = value;
      }
    }
    if (fields.length === 0) return;
    fields.push("updated_at = @updated_at");
    values.updated_at = new Date().toISOString();
    this.db.prepare(`UPDATE projects SET ${fields.join(", ")} WHERE id = @id`).run(values);
  }

  // ── Runs ────────────────────────────────────────────────────────────

  createRun(
    projectId: string,
    seedId: string,
    agentType: Run["agent_type"],
    worktreePath?: string,
    opts?: { baseBranch?: string | null; mergeStrategy?: Run["merge_strategy"] },
  ): Run {
    const now = new Date().toISOString();
    const run: Run = {
      id: randomUUID(),
      project_id: projectId,
      seed_id: seedId,
      agent_type: agentType,
      session_key: null,
      worktree_path: worktreePath ?? null,
      status: "pending",
      started_at: null,
      completed_at: null,
      created_at: now,
      progress: null,
      tmux_session: null,
      base_branch: opts?.baseBranch ?? null,
      merge_strategy: opts?.mergeStrategy ?? 'auto',
    };
    this.db
      .prepare(
        `INSERT INTO runs (id, project_id, seed_id, agent_type, session_key, worktree_path, status, started_at, completed_at, created_at, base_branch, merge_strategy)
         VALUES (@id, @project_id, @seed_id, @agent_type, @session_key, @worktree_path, @status, @started_at, @completed_at, @created_at, @base_branch, @merge_strategy)`
      )
      .run(run);
    return run;
  }

  updateRun(
    id: string,
    updates: Partial<Pick<Run, "status" | "session_key" | "worktree_path" | "started_at" | "completed_at" | "base_branch" | "merge_strategy">>
  ): void {
    const fields: string[] = [];
    const values: Record<string, unknown> = { id };
    for (const [key, value] of Object.entries(updates)) {
      if (value !== undefined) {
        fields.push(`${key} = @${key}`);
        values[key] = value;
      }
    }
    if (fields.length === 0) return;
    this.db.prepare(`UPDATE runs SET ${fields.join(", ")} WHERE id = @id`).run(values);
  }

  getRun(id: string): Run | null {
    return (
      (this.db.prepare("SELECT * FROM runs WHERE id = ?").get(id) as Run | undefined) ?? null
    );
  }

  getActiveRuns(projectId?: string): Run[] {
    if (projectId) {
      return this.db
        .prepare(
          "SELECT * FROM runs WHERE project_id = ? AND status IN ('pending', 'running') ORDER BY created_at DESC"
        )
        .all(projectId) as Run[];
    }
    return this.db
      .prepare(
        "SELECT * FROM runs WHERE status IN ('pending', 'running') ORDER BY created_at DESC"
      )
      .all() as Run[];
  }

  getRunsByStatus(status: Run["status"], projectId?: string): Run[] {
    if (projectId) {
      return this.db
        .prepare(
          "SELECT * FROM runs WHERE project_id = ? AND status = ? ORDER BY created_at DESC"
        )
        .all(projectId, status) as Run[];
    }
    return this.db
      .prepare("SELECT * FROM runs WHERE status = ? ORDER BY created_at DESC")
      .all(status) as Run[];
  }

  /**
   * Fetch runs whose status is any of the given values.
   * Used by Refinery.getCompletedRuns() to find retry-eligible runs when a seedId
   * filter is active (e.g. after a test-failed or conflict).
   */
  getRunsByStatuses(statuses: Run["status"][], projectId?: string): Run[] {
    if (statuses.length === 0) return [];
    const placeholders = statuses.map(() => "?").join(", ");
    if (projectId) {
      return this.db
        .prepare(
          `SELECT * FROM runs WHERE project_id = ? AND status IN (${placeholders}) ORDER BY created_at DESC`
        )
        .all(projectId, ...statuses) as Run[];
    }
    return this.db
      .prepare(`SELECT * FROM runs WHERE status IN (${placeholders}) ORDER BY created_at DESC`)
      .all(...statuses) as Run[];
  }

  getRunsByStatusSince(status: Run["status"], since: string, projectId?: string): Run[] {
    if (projectId) {
      return this.db
        .prepare(
          "SELECT * FROM runs WHERE project_id = ? AND status = ? AND created_at >= ? ORDER BY created_at DESC"
        )
        .all(projectId, status, since) as Run[];
    }
    return this.db
      .prepare("SELECT * FROM runs WHERE status = ? AND created_at >= ? ORDER BY created_at DESC")
      .all(status, since) as Run[];
  }

  /**
   * Fetch runs matching any of the given statuses created on or after `since`.
   * Used by the dispatcher's onError=stop guard to check for recent failures.
   */
  getRunsByStatusesSince(statuses: Run["status"][], since: string, projectId?: string): Run[] {
    if (statuses.length === 0) return [];
    const placeholders = statuses.map(() => "?").join(", ");
    if (projectId) {
      return this.db
        .prepare(
          `SELECT * FROM runs WHERE project_id = ? AND status IN (${placeholders}) AND created_at >= ? ORDER BY created_at DESC`
        )
        .all(projectId, ...statuses, since) as Run[];
    }
    return this.db
      .prepare(
        `SELECT * FROM runs WHERE status IN (${placeholders}) AND created_at >= ? ORDER BY created_at DESC`
      )
      .all(...statuses, since) as Run[];
  }

  /**
   * Purge old runs in terminal states (failed, merged, test-failed, conflict)
   * that are older than the given cutoff date. Returns number of rows deleted.
   */
  purgeOldRuns(olderThan: string, projectId?: string): number {
    const terminalStatuses = ["failed", "merged", "test-failed", "conflict"];
    const placeholders = terminalStatuses.map(() => "?").join(", ");

    if (projectId) {
      const result = this.db
        .prepare(
          `DELETE FROM runs WHERE project_id = ? AND status IN (${placeholders}) AND created_at < ?`
        )
        .run(projectId, ...terminalStatuses, olderThan);
      return result.changes;
    }
    const result = this.db
      .prepare(
        `DELETE FROM runs WHERE status IN (${placeholders}) AND created_at < ?`
      )
      .run(...terminalStatuses, olderThan);
    return result.changes;
  }

  /**
   * Delete a single run record by ID.
   * Returns true if a row was deleted, false if no such run existed.
   */
  deleteRun(runId: string): boolean {
    const result = this.db.prepare("DELETE FROM runs WHERE id = ?").run(runId);
    return result.changes > 0;
  }

  getRunsForSeed(seedId: string, projectId?: string): Run[] {
    if (projectId) {
      return this.db
        .prepare(
          "SELECT * FROM runs WHERE project_id = ? AND seed_id = ? ORDER BY created_at DESC, rowid DESC"
        )
        .all(projectId, seedId) as Run[];
    }
    return this.db
      .prepare("SELECT * FROM runs WHERE seed_id = ? ORDER BY created_at DESC, rowid DESC")
      .all(seedId) as Run[];
  }

  /**
   * Check whether a seed already has a non-terminal run in the database.
   *
   * "Non-terminal" means the run is still active or has produced a result that
   * should block a new dispatch (pending, running, completed, stuck, pr-created).
   * Terminal/retryable states (failed, merged, conflict, test-failed, reset) are
   * excluded so that genuinely failed seeds can be retried.
   *
   * Used by the dispatcher as a just-in-time guard immediately before calling
   * createRun(), preventing duplicate dispatches when two dispatch cycles race
   * and both observe an empty activeRuns snapshot.
   *
   * @returns true if the seed should be skipped (a non-terminal run exists),
   *          false if it is safe to dispatch.
   */
  hasActiveOrPendingRun(seedId: string, projectId?: string): boolean {
    // Statuses that represent "work is in flight or done and not reset"
    const blockingStatuses = ["pending", "running", "completed", "stuck", "pr-created"];
    const placeholders = blockingStatuses.map(() => "?").join(", ");
    let row: unknown;
    if (projectId) {
      row = this.db
        .prepare(
          `SELECT 1 FROM runs WHERE project_id = ? AND seed_id = ? AND status IN (${placeholders}) LIMIT 1`
        )
        .get(projectId, seedId, ...blockingStatuses);
    } else {
      row = this.db
        .prepare(
          `SELECT 1 FROM runs WHERE seed_id = ? AND status IN (${placeholders}) LIMIT 1`
        )
        .get(seedId, ...blockingStatuses);
    }
    return row !== undefined && row !== null;
  }

  /**
   * Find all runs that were branched from the given base branch (i.e. stacked on it).
   * Used by rebaseStackedBranches() to find dependent seeds after a merge.
   */
  getRunsByBaseBranch(baseBranch: string, projectId?: string): Run[] {
    if (projectId) {
      return this.db
        .prepare(
          "SELECT * FROM runs WHERE project_id = ? AND base_branch = ? ORDER BY created_at DESC"
        )
        .all(projectId, baseBranch) as Run[];
    }
    return this.db
      .prepare("SELECT * FROM runs WHERE base_branch = ? ORDER BY created_at DESC")
      .all(baseBranch) as Run[];
  }

  getRunEvents(runId: string, eventType?: EventType): Event[] {
    if (eventType) {
      return this.db
        .prepare("SELECT * FROM events WHERE run_id = ? AND event_type = ? ORDER BY created_at DESC")
        .all(runId, eventType) as Event[];
    }
    return this.db
      .prepare("SELECT * FROM events WHERE run_id = ? ORDER BY created_at DESC")
      .all(runId) as Event[];
  }

  // ── Progress ─────────────────────────────────────────────────────────

  updateRunProgress(runId: string, progress: RunProgress): void {
    this.db
      .prepare("UPDATE runs SET progress = ? WHERE id = ?")
      .run(JSON.stringify(progress), runId);
  }

  getRunProgress(runId: string): RunProgress | null {
    const row = this.db
      .prepare("SELECT progress FROM runs WHERE id = ?")
      .get(runId) as { progress: string | null } | undefined;
    if (!row?.progress) return null;
    return JSON.parse(row.progress) as RunProgress;
  }

  // ── Costs ───────────────────────────────────────────────────────────

  recordCost(
    runId: string,
    tokensIn: number,
    tokensOut: number,
    cacheRead: number,
    estimatedCost: number
  ): void {
    this.db
      .prepare(
        `INSERT INTO costs (id, run_id, tokens_in, tokens_out, cache_read, estimated_cost, recorded_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)`
      )
      .run(randomUUID(), runId, tokensIn, tokensOut, cacheRead, estimatedCost, new Date().toISOString());
  }

  getCosts(projectId?: string, since?: string): Cost[] {
    if (projectId && since) {
      return this.db
        .prepare(
          `SELECT c.* FROM costs c
           JOIN runs r ON c.run_id = r.id
           WHERE r.project_id = ? AND c.recorded_at >= ?
           ORDER BY c.recorded_at DESC`
        )
        .all(projectId, since) as Cost[];
    }
    if (projectId) {
      return this.db
        .prepare(
          `SELECT c.* FROM costs c
           JOIN runs r ON c.run_id = r.id
           WHERE r.project_id = ?
           ORDER BY c.recorded_at DESC`
        )
        .all(projectId) as Cost[];
    }
    if (since) {
      return this.db
        .prepare("SELECT * FROM costs WHERE recorded_at >= ? ORDER BY recorded_at DESC")
        .all(since) as Cost[];
    }
    return this.db.prepare("SELECT * FROM costs ORDER BY recorded_at DESC").all() as Cost[];
  }

  /**
   * Get per-phase and per-agent cost breakdown for a single run.
   * Returns empty records if the run has no phase cost data (backwards compatible).
   */
  getCostBreakdown(runId: string): { byPhase: Record<string, number>; byAgent: Record<string, number> } {
    const progress = this.getRunProgress(runId);
    if (!progress) {
      return { byPhase: {}, byAgent: {} };
    }

    const byPhase: Record<string, number> = { ...(progress.costByPhase ?? {}) };

    // Build byAgent by summing costs per model across phases
    const byAgent: Record<string, number> = {};
    if (progress.costByPhase && progress.agentByPhase) {
      for (const [phase, cost] of Object.entries(progress.costByPhase)) {
        const agent = progress.agentByPhase[phase];
        if (agent) {
          byAgent[agent] = (byAgent[agent] ?? 0) + cost;
        }
      }
    }

    return { byPhase, byAgent };
  }

  /**
   * Aggregate phase costs across all runs in a project.
   * Reads per-phase cost data stored in progress JSON.
   */
  getPhaseMetrics(projectId?: string, since?: string): {
    totalByPhase: Record<string, number>;
    totalByAgent: Record<string, number>;
    runsByPhase: Record<string, number>;
  } {
    const conditions: string[] = [];
    const params: unknown[] = [];
    if (projectId) {
      conditions.push("project_id = ?");
      params.push(projectId);
    }
    if (since) {
      conditions.push("created_at >= ?");
      params.push(since);
    }
    const where = conditions.length ? `WHERE ${conditions.join(" AND ")}` : "";

    const rows = this.db
      .prepare(`SELECT progress FROM runs ${where}`)
      .all(...params) as Array<{ progress: string | null }>;

    const totalByPhase: Record<string, number> = {};
    const totalByAgent: Record<string, number> = {};
    const runsByPhase: Record<string, number> = {};

    for (const row of rows) {
      if (!row.progress) continue;
      try {
        const progress = JSON.parse(row.progress) as RunProgress;
        if (!progress.costByPhase) continue;

        for (const [phase, cost] of Object.entries(progress.costByPhase)) {
          totalByPhase[phase] = (totalByPhase[phase] ?? 0) + cost;
          runsByPhase[phase] = (runsByPhase[phase] ?? 0) + 1;
        }

        if (progress.agentByPhase) {
          for (const [phase, agent] of Object.entries(progress.agentByPhase)) {
            const cost = progress.costByPhase[phase] ?? 0;
            totalByAgent[agent] = (totalByAgent[agent] ?? 0) + cost;
          }
        }
      } catch {
        // Ignore malformed progress
      }
    }

    return { totalByPhase, totalByAgent, runsByPhase };
  }

  // ── Success Rate ─────────────────────────────────────────────────────

  /**
   * Compute the 24-hour pipeline success rate for a project.
   *
   * Success rate = merged / (merged + test-failed + failed), where:
   * - "merged" includes both `merged` and `pr-created` statuses
   * - `completed` (pending merge), `reset`, `running`, `pending`, `stuck` are excluded
   *
   * Returns `{ rate: null, merged: 0, failed: 0 }` when fewer than 3 terminal
   * runs have completed in the last 24 hours (not enough data to be meaningful).
   *
   * @param projectId - Scope to a specific project; omit for global.
   */
  getSuccessRate(projectId?: string): { rate: number | null; merged: number; failed: number } {
    const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
    const statuses = ["merged", "test-failed", "failed", "pr-created", "reset"];
    const placeholders = statuses.map(() => "?").join(", ");

    let rows: Array<{ status: string; count: number }>;
    if (projectId) {
      rows = this.db
        .prepare(
          `SELECT status, COUNT(*) as count FROM runs
           WHERE project_id = ? AND completed_at > ? AND status IN (${placeholders})
           GROUP BY status`,
        )
        .all(projectId, since, ...statuses) as Array<{ status: string; count: number }>;
    } else {
      rows = this.db
        .prepare(
          `SELECT status, COUNT(*) as count FROM runs
           WHERE completed_at > ? AND status IN (${placeholders})
           GROUP BY status`,
        )
        .all(since, ...statuses) as Array<{ status: string; count: number }>;
    }

    const counts: Record<string, number> = {};
    for (const row of rows) {
      counts[row.status] = row.count;
    }

    const merged = (counts["merged"] ?? 0) + (counts["pr-created"] ?? 0);
    const failed = (counts["failed"] ?? 0) + (counts["test-failed"] ?? 0) + (counts["reset"] ?? 0);
    const total = merged + failed;

    // Require at least 3 terminal runs before showing a percentage
    if (total < 3) {
      return { rate: null, merged, failed };
    }

    return { rate: merged / total, merged, failed };
  }

  // ── Events ──────────────────────────────────────────────────────────

  logEvent(
    projectId: string,
    eventType: EventType,
    details?: Record<string, unknown> | string,
    runId?: string
  ): void {
    const detailsStr = details
      ? typeof details === "string"
        ? details
        : JSON.stringify(details)
      : null;
    this.db
      .prepare(
        `INSERT INTO events (id, project_id, run_id, event_type, details, created_at)
         VALUES (?, ?, ?, ?, ?, ?)`
      )
      .run(randomUUID(), projectId, runId ?? null, eventType, detailsStr, new Date().toISOString());
  }

  getEvents(projectId?: string, limit?: number, eventType?: string): Event[] {
    const conditions: string[] = [];
    const params: unknown[] = [];
    if (projectId) {
      conditions.push("project_id = ?");
      params.push(projectId);
    }
    if (eventType) {
      conditions.push("event_type = ?");
      params.push(eventType);
    }
    const where = conditions.length ? `WHERE ${conditions.join(" AND ")}` : "";
    const limitClause = limit ? `LIMIT ?` : "";
    if (limit) params.push(limit);
    return this.db
      .prepare(`SELECT * FROM events ${where} ORDER BY created_at DESC ${limitClause}`)
      .all(...params) as Event[];
  }

  // ── Rate Limit Events (P2: per-model rate limit tracking) ─────────────────────

  /**
   * Log a rate limit event when a 429 is detected.
   * This enables per-model rate limit tracking and alerting.
   */
  logRateLimitEvent(
    projectId: string,
    model: string,
    phase: string | undefined,
    error: string,
    retryAfterSeconds?: number,
    runId?: string
  ): void {
    this.db
      .prepare(
        `INSERT INTO rate_limit_events (id, project_id, run_id, model, phase, error, retry_after_seconds, recorded_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
      )
      .run(
        randomUUID(),
        projectId,
        runId ?? null,
        model,
        phase ?? null,
        error,
        retryAfterSeconds ?? null,
        new Date().toISOString()
      );
  }

  /**
   * Get rate limit event counts grouped by model for the last N hours.
   * Used for visualization and alerting (P2, P3 recommendations).
   */
  getRateLimitCountsByModel(projectId: string, hoursBack = 24): Record<string, number> {
    const since = new Date(Date.now() - hoursBack * 60 * 60 * 1000).toISOString();
    const rows = this.db
      .prepare(
        `SELECT model, COUNT(*) as count FROM rate_limit_events
         WHERE project_id = ? AND recorded_at > ?
         GROUP BY model`
      )
      .all(projectId, since) as Array<{ model: string; count: number }>;
    const result: Record<string, number> = {};
    for (const row of rows) {
      result[row.model] = row.count;
    }
    return result;
  }

  /**
   * Get recent rate limit events for alerting purposes.
   */
  getRecentRateLimitEvents(projectId: string, limit = 10): Array<{
    id: string;
    model: string;
    phase: string | null;
    error: string;
    retry_after_seconds: number | null;
    recorded_at: string;
  }> {
    return this.db
      .prepare(
        `SELECT id, model, phase, error, retry_after_seconds, recorded_at
         FROM rate_limit_events
         WHERE project_id = ?
         ORDER BY recorded_at DESC
         LIMIT ?`
      )
      .all(projectId, limit) as Array<{
        id: string;
        model: string;
        phase: string | null;
        error: string;
        retry_after_seconds: number | null;
        recorded_at: string;
      }>;
  }

  // ── Messaging ───────────────────────────────────────────────────────

  /**
   * Send a message from one agent to another within a run.
   * Messages are scoped by run_id so agents in different runs cannot cross-communicate.
   */
  sendMessage(
    runId: string,
    senderAgentType: string,
    recipientAgentType: string,
    subject: string,
    body: string
  ): Message {
    const now = new Date().toISOString();
    const message: Message = {
      id: randomUUID(),
      run_id: runId,
      sender_agent_type: senderAgentType,
      recipient_agent_type: recipientAgentType,
      subject,
      body,
      read: 0,
      created_at: now,
      deleted_at: null,
    };
    this.db
      .prepare(
        `INSERT INTO messages
           (id, run_id, sender_agent_type, recipient_agent_type, subject, body, read, created_at, deleted_at)
         VALUES
           (@id, @run_id, @sender_agent_type, @recipient_agent_type, @subject, @body, @read, @created_at, @deleted_at)`
      )
      .run(message);
    return message;
  }

  /**
   * Get messages for an agent in a run.
   * @param runId - The run to scope messages to
   * @param agentType - The recipient agent type
   * @param unreadOnly - If true, only return unread messages (default: false)
   */
  getMessages(runId: string, agentType: string, unreadOnly = false): Message[] {
    if (unreadOnly) {
      return this.db
        .prepare(
          `SELECT * FROM messages
           WHERE run_id = ? AND recipient_agent_type = ? AND read = 0 AND deleted_at IS NULL
           ORDER BY created_at ASC, rowid ASC`
        )
        .all(runId, agentType) as Message[];
    }
    return this.db
      .prepare(
        `SELECT * FROM messages
         WHERE run_id = ? AND recipient_agent_type = ? AND deleted_at IS NULL
         ORDER BY created_at ASC, rowid ASC`
      )
      .all(runId, agentType) as Message[];
  }

  /**
   * Get all messages in a run (for lead/coordinator visibility).
   */
  getAllMessages(runId: string): Message[] {
    return this.db
      .prepare(
        `SELECT * FROM messages
         WHERE run_id = ? AND deleted_at IS NULL
         ORDER BY created_at ASC, rowid ASC`
      )
      .all(runId) as Message[];
  }

  /**
   * Get all messages across all runs (for global watch mode).
   */
  getAllMessagesGlobal(limit = 200): Message[] {
    // Fetch the most recent messages (DESC), then reverse to display chronologically.
    // Without this, --all shows the oldest messages from the beginning of time.
    const rows = this.db
      .prepare(
        `SELECT * FROM messages
         WHERE deleted_at IS NULL
         ORDER BY created_at DESC, rowid DESC
         LIMIT ?`
      )
      .all(limit) as Message[];
    return rows.reverse();
  }

  /**
   * Mark a message as read.
   * @returns true if the message was found and updated, false if no such message exists.
   */
  markMessageRead(messageId: string): boolean {
    const result = this.db
      .prepare("UPDATE messages SET read = 1 WHERE id = ?")
      .run(messageId);
    return result.changes > 0;
  }

  /**
   * Mark all messages for an agent in a run as read.
   *
   * The `deleted_at IS NULL` guard is intentional: soft-deleted messages are
   * excluded from all normal queries and should not be resurrected by a bulk
   * read — they remain "deleted" and do not count as unread.
   */
  markAllMessagesRead(runId: string, agentType: string): void {
    this.db
      .prepare(
        "UPDATE messages SET read = 1 WHERE run_id = ? AND recipient_agent_type = ? AND deleted_at IS NULL"
      )
      .run(runId, agentType);
  }

  /**
   * Soft-delete a message (sets deleted_at timestamp).
   * @returns true if the message was found and soft-deleted, false if no such message exists.
   */
  deleteMessage(messageId: string): boolean {
    const result = this.db
      .prepare("UPDATE messages SET deleted_at = ? WHERE id = ?")
      .run(new Date().toISOString(), messageId);
    return result.changes > 0;
  }

  /**
   * Get a single message by ID.
   */
  getMessage(messageId: string): Message | null {
    return (
      (this.db.prepare("SELECT * FROM messages WHERE id = ?").get(messageId) as Message | undefined) ??
      null
    );
  }

  // ── Bead Write Queue ─────────────────────────────────────────────────

  /**
   * Enqueue a bead write operation for sequential processing by the dispatcher.
   *
   * Called by agent-workers, refinery, pipeline-executor, and auto-merge
   * instead of invoking the br CLI directly. The dispatcher drains this queue
   * and executes br commands one at a time, eliminating SQLite lock contention.
   *
   * @param sender - Human-readable source identifier (e.g. "agent-worker", "refinery")
   * @param operation - Operation type: "close-seed" | "reset-seed" | "mark-failed" | "add-notes" | "add-labels"
   * @param payload - Operation-specific data (will be JSON-stringified)
   */
  enqueueBeadWrite(sender: string, operation: string, payload: unknown): void {
    const entry: BeadWriteEntry = {
      id: randomUUID(),
      sender,
      operation,
      payload: JSON.stringify(payload),
      created_at: new Date().toISOString(),
      processed_at: null,
    };
    this.db
      .prepare(
        `INSERT INTO bead_write_queue (id, sender, operation, payload, created_at, processed_at)
         VALUES (@id, @sender, @operation, @payload, @created_at, @processed_at)`
      )
      .run(entry);
  }

  /**
   * Retrieve all pending (unprocessed) bead write entries in insertion order.
   * Returns entries where processed_at IS NULL, ordered by created_at ASC.
   */
  getPendingBeadWrites(): BeadWriteEntry[] {
    return this.db
      .prepare(
        `SELECT * FROM bead_write_queue
         WHERE processed_at IS NULL
         ORDER BY created_at ASC, rowid ASC`
      )
      .all() as BeadWriteEntry[];
  }

  /**
   * Mark a bead write entry as processed by setting its processed_at timestamp.
   * @returns true if the entry was found and updated, false otherwise.
   */
  markBeadWriteProcessed(id: string): boolean {
    const result = this.db
      .prepare("UPDATE bead_write_queue SET processed_at = ? WHERE id = ?")
      .run(new Date().toISOString(), id);
    return result.changes > 0;
  }

  // ── Sentinel ─────────────────────────────────────────────────────────

  upsertSentinelConfig(
    projectId: string,
    config: Partial<Omit<SentinelConfigRow, "id" | "project_id" | "created_at" | "updated_at">>
  ): SentinelConfigRow {
    const now = new Date().toISOString();
    const existing = this.getSentinelConfig(projectId);
    if (existing) {
      const fields: string[] = ["updated_at = @updated_at"];
      const values: Record<string, unknown> = { project_id: projectId, updated_at: now };
      for (const [key, value] of Object.entries(config)) {
        if (value !== undefined) {
          fields.push(`${key} = @${key}`);
          values[key] = value;
        }
      }
      this.db.prepare(`UPDATE sentinel_configs SET ${fields.join(", ")} WHERE project_id = @project_id`).run(values);
      return this.getSentinelConfig(projectId)!;
    } else {
      const row: Omit<SentinelConfigRow, "id"> = {
        project_id: projectId,
        branch: config.branch ?? "main",
        test_command: config.test_command ?? "npm test",
        interval_minutes: config.interval_minutes ?? 30,
        failure_threshold: config.failure_threshold ?? 2,
        enabled: config.enabled ?? 1,
        pid: config.pid ?? null,
        created_at: now,
        updated_at: now,
      };
      this.db.prepare(
        `INSERT INTO sentinel_configs (project_id, branch, test_command, interval_minutes, failure_threshold, enabled, pid, created_at, updated_at)
         VALUES (@project_id, @branch, @test_command, @interval_minutes, @failure_threshold, @enabled, @pid, @created_at, @updated_at)`
      ).run(row);
      return this.getSentinelConfig(projectId)!;
    }
  }

  getSentinelConfig(projectId: string): SentinelConfigRow | null {
    return (
      (this.db.prepare("SELECT * FROM sentinel_configs WHERE project_id = ?").get(projectId) as SentinelConfigRow | undefined) ?? null
    );
  }

  recordSentinelRun(run: Omit<SentinelRunRow, "failure_count"> & { failure_count?: number }): void {
    this.db.prepare(
      `INSERT INTO sentinel_runs (id, project_id, branch, commit_hash, status, test_command, output, failure_count, started_at, completed_at)
       VALUES (@id, @project_id, @branch, @commit_hash, @status, @test_command, @output, @failure_count, @started_at, @completed_at)`
    ).run({
      id: run.id,
      project_id: run.project_id,
      branch: run.branch,
      commit_hash: run.commit_hash ?? null,
      status: run.status,
      test_command: run.test_command,
      output: run.output ?? null,
      failure_count: run.failure_count ?? 0,
      started_at: run.started_at,
      completed_at: run.completed_at ?? null,
    });
  }

  updateSentinelRun(id: string, updates: Partial<Pick<SentinelRunRow, "status" | "output" | "completed_at" | "failure_count">>): void {
    const fields: string[] = [];
    const values: Record<string, unknown> = { id };
    for (const [key, value] of Object.entries(updates)) {
      if (value !== undefined) {
        fields.push(`${key} = @${key}`);
        values[key] = value;
      }
    }
    if (fields.length === 0) return;
    this.db.prepare(`UPDATE sentinel_runs SET ${fields.join(", ")} WHERE id = @id`).run(values);
  }

  getSentinelRuns(projectId?: string, limit?: number): SentinelRunRow[] {
    const conditions: string[] = [];
    const params: unknown[] = [];
    if (projectId) {
      conditions.push("project_id = ?");
      params.push(projectId);
    }
    const where = conditions.length ? `WHERE ${conditions.join(" AND ")}` : "";
    const limitClause = limit ? `LIMIT ?` : "";
    if (limit) params.push(limit);
    return this.db
      .prepare(`SELECT * FROM sentinel_runs ${where} ORDER BY started_at DESC ${limitClause}`)
      .all(...params) as SentinelRunRow[];
  }

  // ── Merge Agent Config ───────────────────────────────────────────────

  /**
   * Get the merge agent configuration row (singleton with id='default').
   * Returns null if not yet initialized (before `foreman init`).
   */
  getMergeAgentConfig(): MergeAgentConfigRow | null {
    return (
      (this.db
        .prepare("SELECT * FROM merge_agent_config WHERE id = 'default'")
        .get() as MergeAgentConfigRow | undefined) ?? null
    );
  }

  /**
   * Create or update the merge agent configuration.
   * Upserts the singleton 'default' row.
   */
  setMergeAgentConfig(
    config: Partial<Omit<MergeAgentConfigRow, "id" | "created_at" | "updated_at">>
  ): MergeAgentConfigRow {
    const now = new Date().toISOString();
    const existing = this.getMergeAgentConfig();

    if (existing) {
      const fields: string[] = ["updated_at = @updated_at"];
      const values: Record<string, unknown> = { updated_at: now };

      if (config.enabled !== undefined) {
        fields.push("enabled = @enabled");
        values.enabled = config.enabled;
      }
      if (config.poll_interval_ms !== undefined) {
        fields.push("poll_interval_ms = @poll_interval_ms");
        values.poll_interval_ms = config.poll_interval_ms;
      }

      this.db
        .prepare(`UPDATE merge_agent_config SET ${fields.join(", ")} WHERE id = 'default'`)
        .run(values);
    } else {
      this.db
        .prepare(
          `INSERT INTO merge_agent_config (id, enabled, poll_interval_ms, created_at, updated_at)
           VALUES ('default', @enabled, @poll_interval_ms, @created_at, @updated_at)`
        )
        .run({
          enabled: config.enabled ?? 1,
          poll_interval_ms: config.poll_interval_ms ?? 30_000,
          created_at: now,
          updated_at: now,
        });
    }

    return this.getMergeAgentConfig()!;
  }

  // ── Metrics ─────────────────────────────────────────────────────────

  getMetrics(projectId?: string, since?: string): Metrics {
    const costConditions: string[] = [];
    const costParams: unknown[] = [];
    if (projectId) {
      costConditions.push("r.project_id = ?");
      costParams.push(projectId);
    }
    if (since) {
      costConditions.push("c.recorded_at >= ?");
      costParams.push(since);
    }
    const costWhere = costConditions.length
      ? `WHERE ${costConditions.join(" AND ")}`
      : "";

    const totals = this.db
      .prepare(
        `SELECT COALESCE(SUM(c.estimated_cost), 0) as totalCost,
                COALESCE(SUM(c.tokens_in + c.tokens_out), 0) as totalTokens
         FROM costs c
         JOIN runs r ON c.run_id = r.id
         ${costWhere}`
      )
      .get(...costParams) as { totalCost: number; totalTokens: number };

    // Tasks by status
    const runConditions: string[] = [];
    const runParams: unknown[] = [];
    if (projectId) {
      runConditions.push("project_id = ?");
      runParams.push(projectId);
    }
    if (since) {
      runConditions.push("created_at >= ?");
      runParams.push(since);
    }
    const runWhere = runConditions.length
      ? `WHERE ${runConditions.join(" AND ")}`
      : "";

    const statusRows = this.db
      .prepare(`SELECT status, COUNT(*) as count FROM runs ${runWhere} GROUP BY status`)
      .all(...runParams) as Array<{ status: string; count: number }>;

    const tasksByStatus: Record<string, number> = {};
    for (const row of statusRows) {
      tasksByStatus[row.status] = row.count;
    }

    // Cost by runtime
    const costByRuntime = this.db
      .prepare(
        `SELECT r.id as run_id,
                COALESCE(SUM(c.estimated_cost), 0) as cost,
                CASE WHEN r.started_at IS NOT NULL AND r.completed_at IS NOT NULL
                     THEN CAST((julianday(r.completed_at) - julianday(r.started_at)) * 86400 AS INTEGER)
                     ELSE NULL END as duration_seconds
         FROM runs r
         LEFT JOIN costs c ON c.run_id = r.id
         ${runWhere}
         GROUP BY r.id
         ORDER BY cost DESC`
      )
      .all(...runParams) as Metrics["costByRuntime"];

    // Phase & agent cost breakdown (aggregated from run progress JSON)
    const phaseMetrics = this.getPhaseMetrics(projectId, since);

    return {
      totalCost: totals.totalCost,
      totalTokens: totals.totalTokens,
      tasksByStatus,
      costByRuntime,
      costByPhase: Object.keys(phaseMetrics.totalByPhase).length > 0
        ? phaseMetrics.totalByPhase
        : undefined,
      agentCostBreakdown: Object.keys(phaseMetrics.totalByAgent).length > 0
        ? phaseMetrics.totalByAgent
        : undefined,
    };
  }

  // ── Native Task Store (PRD-2026-006 REQ-003 / REQ-017) ──────────────

  /**
   * Check whether the native `tasks` table exists and contains at least one row.
   *
   * Used by the dispatcher to decide whether to query the native store or fall
   * back to the BeadsRustClient (br) CLI.  Returns false if the table is missing
   * (schema not yet applied) or empty.
   */
  hasNativeTasks(): boolean {
    try {
      const row = this.db
        .prepare("SELECT COUNT(*) as cnt FROM tasks")
        .get() as { cnt: number } | undefined;
      return (row?.cnt ?? 0) > 0;
    } catch {
      return false;
    }
  }

  /**
   * Look up a native task by external_id.
   *
   * Used when an explicit bead ID may correspond to a native task row in auto mode.
   * Returns null when the tasks table is missing or no row matches.
   */
  getTaskByExternalId(externalId: string): NativeTask | null {
    try {
      return (
        (this.db
          .prepare("SELECT * FROM tasks WHERE external_id = ? LIMIT 1")
          .get(externalId) as NativeTask | undefined) ?? null
      );
    } catch {
      return null;
    }
  }

  /**
   * Return all tasks with status = 'ready', ordered by priority ASC then created_at ASC.
   *
   * Implements REQ-017 AC-017.1: "SELECT * FROM tasks WHERE status = 'ready'
   * ORDER BY priority ASC, created_at ASC".
   */
  getReadyTasks(): NativeTask[] {
    return this.db
      .prepare(
        `SELECT * FROM tasks
         WHERE status = 'ready'
         ORDER BY priority ASC, created_at ASC`,
      )
      .all() as NativeTask[];
  }

  /**
   * Atomically claim a task by transitioning its status from 'ready' to 'in-progress'
   * and recording the associated run_id in a single SQLite transaction.
   *
   * Implements REQ-017 AC-017.2: the UPDATE is atomic — if two concurrent dispatcher
   * instances attempt to claim the same task, exactly one succeeds (the WHERE clause
   * only matches rows still in status='ready').
   *
   * @param taskId - The task ID to claim.
   * @param runId  - The run ID to associate with the claimed task.
   * @returns true if the task was claimed (row affected), false if it was already
   *          claimed by another process (0 rows affected).
   */
  claimTask(taskId: string, runId: string): boolean {
    const now = new Date().toISOString();
    const result = this.db
      .prepare(
        `UPDATE tasks
         SET status = 'in-progress', run_id = @runId, updated_at = @now
         WHERE id = @taskId AND status = 'ready'`,
      )
      .run({ taskId, runId, now });
    return result.changes > 0;
  }
}
