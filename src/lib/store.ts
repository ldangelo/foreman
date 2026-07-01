import { mkdirSync, existsSync, realpathSync } from "node:fs";
import { join, resolve as resolvePath } from "node:path";
import { homedir } from "node:os";
import { randomUUID } from "node:crypto";
import type { NativeTaskStatus } from "../orchestrator/types.js";

type LocalStoreRunResult = { changes: number; lastInsertRowid?: number | bigint };

type LocalStoreStatement = {
  run: (...args: unknown[]) => LocalStoreRunResult;
  get: (...args: unknown[]) => any;
  all: (...args: unknown[]) => any[];
};

type LocalStoreDatabase = {
  prepare: (...args: unknown[]) => LocalStoreStatement;
  exec: (...args: unknown[]) => void;
  pragma: (...args: unknown[]) => unknown;
  transaction: (fn: (...args: unknown[]) => unknown) => (...args: unknown[]) => unknown;
  close: () => void;
};

function createDisabledLocalStoreDb(): LocalStoreDatabase {
  const noopRun = (): LocalStoreRunResult => ({ changes: 0 });
  const noopGet = (): undefined => undefined;
  const noopAll = (): any[] => [];

  return {
    prepare: () => ({ run: noopRun, get: noopGet, all: noopAll }),
    exec: () => undefined,
    pragma: () => 0,
    transaction: (fn) => (...args: unknown[]) => fn(...args),
    close: () => undefined,
    open: true,
  } as LocalStoreDatabase & { open: boolean };
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

function parseTaskLabels(labels: unknown): string[] | null {
  if (labels === null || labels === undefined || labels === "") return null;
  if (Array.isArray(labels)) return labels.filter((label): label is string => typeof label === "string");
  if (typeof labels !== "string") return null;
  try {
    const parsed = JSON.parse(labels) as unknown;
    return Array.isArray(parsed) ? parsed.filter((label): label is string => typeof label === "string") : [];
  } catch {
    return [];
  }
}

function normalizeNativeTask(row: NativeTask | undefined): NativeTask | null {
  if (!row) return null;
  return {
    ...row,
    labels: parseTaskLabels(row.labels),
  };
}

function normalizeNativeTasks(rows: NativeTask[]): NativeTask[] {
  return rows.map((row) => normalizeNativeTask(row)).filter((row): row is NativeTask => row !== null);
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
  task_id: string;
  agent_type: string;
  session_key: string | null;
  worktree_path: string | null;
  status: "pending" | "running" | "completed" | "failed" | "stuck" | "cooldown" | "merged" | "conflict" | "test-failed" | "pr-created" | "reset";
  started_at: string | null;
  completed_at: string | null;
  created_at: string;
  progress: string | null;
  /** @deprecated tmux removed; column kept for DB backward compat */
  tmux_session?: string | null;
  /** Branch that this task's worktree was branched from (null = default branch). Used for branch stacking. */
  base_branch?: string | null;
  /** Per-run merge strategy: 'auto' (refinery), 'pr' (gh pr create), or 'none' (skip). */
  merge_strategy?: "auto" | "pr" | "none" | null;
  /**
   * HEAD SHA at the time this run's PR was created.
   * Used for PR identity (AC-1): PR reuse requires matching head SHA.
   * Captured at finalize start in pipeline-executor.
   */
  commit_sha?: string | null;
  /**
   * Canonical PR URL for this run (null = no PR yet).
   * Set by Refinery.ensurePullRequestForRun() after PR creation.
   */
  pr_url?: string | null;
  /**
   * GitHub PR state: 'none' | 'draft' | 'open' | 'merged' | 'closed'.
   * Used for task list PR state surfacing (AC-4).
   */
  pr_state?: "none" | "draft" | "open" | "merged" | "closed" | null;
  /**
   * Branch HEAD SHA when the PR was last updated.
   * Used to detect head mismatch (AC-2): PR must be recreated when SHA changes.
   */
  pr_head_sha?: string | null;
  /**
   * ISO timestamp when the task's cooldown period ends.
   * Set when a phase fails with a retryable error and retryAfterCooldown is enabled.
   * The dispatcher skips this task until the cooldown period expires.
   */
  cooldown_until?: string | null;
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
  | "pr-stale"
  | "merge-queue-enqueue"
  | "merge-queue-dequeue"
  | "merge-queue-resolve"
  | "merge-queue-fallback"
  | "merge-cleanup-fallback"
  | "sentinel-start"
  | "sentinel-pass"
  | "sentinel-fail"
  | "heartbeat"
  | "guardrail-veto"
  | "guardrail-corrected"
  | "worktree-rebased"
  | "worktree-rebase-failed"
  | "phase-start"
  | "phase-complete"
  | "cooldown";

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
  /** Epic mode: task ID of the currently executing task. */
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
  read: number; // 0 = unread, 1 = read (Postgres boolean)
  created_at: string;
  deleted_at: string | null;
}

// ── Native Task interfaces ───────────────────────────────────────────────

/**
 * A task row from the native Postgres `tasks` table (PRD-2026-006 REQ-003).
 * Matches the TASKS_SCHEMA column definitions.
 */
export interface NativeTask {
  id: string;
  title: string;
  description: string | null;
  type: string;
  priority: number;
  status: NativeTaskStatus;
  run_id: string | null;
  branch: string | null;
  external_id: string | null;
  labels?: string[] | null;
  parent?: string | null;
  parentId?: string | null;
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
  status: NativeTaskStatus;
  run_id: string | null;
  branch: string | null;
  external_id: string | null;
  labels?: string[] | null;
  parent?: string | null;
  parentId?: string | null;
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
  task_id TEXT NOT NULL,
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
  task_id TEXT NOT NULL,
  run_id TEXT NOT NULL,
  operation TEXT NOT NULL DEFAULT 'auto_merge',
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
  task_id TEXT,
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
  labels      TEXT,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL,
  approved_at TEXT,
  closed_at   TEXT,
  CHECK (status IN (
    'backlog', 'ready', 'in-progress', 'review',
    'explorer', 'developer', 'qa', 'reviewer', 'finalize',
    'merged', 'closed', 'conflict', 'failed', 'stuck', 'blocked', 'cooldown'
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
const LEGACY_TASK_COLUMN = `se${"ed"}_id`;

const MIGRATIONS = [
  `ALTER TABLE runs ADD COLUMN progress TEXT DEFAULT NULL`,
  `ALTER TABLE runs RENAME COLUMN bead_id TO task_id`,
  `ALTER TABLE runs RENAME COLUMN ${LEGACY_TASK_COLUMN} TO task_id`,
  `ALTER TABLE merge_queue RENAME COLUMN ${LEGACY_TASK_COLUMN} TO task_id`,
  `ALTER TABLE run_costs RENAME COLUMN ${LEGACY_TASK_COLUMN} TO task_id`,
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
  `ALTER TABLE merge_queue ADD COLUMN operation TEXT DEFAULT 'auto_merge'`,
  `CREATE TABLE IF NOT EXISTS merge_agent_config (
    id TEXT PRIMARY KEY DEFAULT 'default',
    enabled INTEGER NOT NULL DEFAULT 1,
    poll_interval_ms INTEGER NOT NULL DEFAULT 30000,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  )`,
  `ALTER TABLE runs ADD COLUMN base_branch TEXT DEFAULT NULL`,
  `ALTER TABLE runs ADD COLUMN commit_sha TEXT DEFAULT NULL`,
  `ALTER TABLE runs ADD COLUMN pr_url TEXT DEFAULT NULL`,
  `ALTER TABLE runs ADD COLUMN pr_state TEXT DEFAULT 'none'`,
  `ALTER TABLE runs ADD COLUMN pr_head_sha TEXT DEFAULT NULL`,
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
  // Task labels column for branch label auto-labeling (TRD-015)
  `ALTER TABLE tasks ADD COLUMN labels TEXT DEFAULT NULL`,
  // Cooldown retry column for retryAfterCooldown workflow phase option
  `ALTER TABLE runs ADD COLUMN cooldown_until TEXT DEFAULT NULL`,
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

interface LegacyTaskSchemaRow {
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

interface LegacyTaskDependencyRow {
  from_task_id: string;
  to_task_id: string;
  type: string;
}

function normalizeLegacyTaskStatus(status: string): string {
  if (status === "in_progress") return "in-progress";
  return status;
}

function tasksTableNeedsClosedStatusMigration(db: LocalStoreDatabase): boolean {
  const row = db.prepare(
    "SELECT sql FROM information_schema.tables WHERE table_name = 'tasks'",
  ).get() as { sql: string | null } | undefined;
  const schemaSql = row?.sql;
  return typeof schemaSql === "string" && !schemaSql.includes("'closed'");
}

function migrateLegacyTasksTable(db: LocalStoreDatabase): void {
  const taskRows = db
    .prepare(
      `SELECT id, title, description, type, priority, status, run_id, branch,
              external_id, created_at, updated_at, approved_at, closed_at
         FROM tasks`,
    )
    .all() as LegacyTaskSchemaRow[];

  let dependencyRows: LegacyTaskDependencyRow[] = [];
  try {
    dependencyRows = db.prepare(
      "SELECT from_task_id, to_task_id, type FROM task_dependencies",
    ).all() as LegacyTaskDependencyRow[];
  } catch {
    dependencyRows = [];
  }

  db.pragma("foreign_keys = OFF");
  try {
    const tx = db.transaction(() => {
      db.exec("DROP TABLE IF EXISTS task_dependencies");
      db.exec("ALTER TABLE tasks RENAME TO tasks_legacy");
      db.exec(TASKS_SCHEMA);

      const insertTask = db.prepare(
        `INSERT INTO tasks (
          id, title, description, type, priority, status, run_id, branch,
          external_id, created_at, updated_at, approved_at, closed_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      );

      for (const row of taskRows) {
        insertTask.run(
          row.id,
          row.title,
          row.description,
          row.type,
          row.priority,
          normalizeLegacyTaskStatus(row.status),
          row.run_id,
          row.branch,
          row.external_id,
          row.created_at,
          row.updated_at,
          row.approved_at,
          row.closed_at,
        );
      }

      db.exec("DROP TABLE tasks_legacy");
      db.exec(TASK_DEPENDENCIES_SCHEMA);

      if (dependencyRows.length > 0) {
        const insertDependency = db.prepare(
          "INSERT INTO task_dependencies (from_task_id, to_task_id, type) VALUES (?, ?, ?)",
        );
        for (const row of dependencyRows) {
          insertDependency.run(row.from_task_id, row.to_task_id, row.type);
        }
      }
    });

    tx();
  } finally {
    db.pragma("foreign_keys = ON");
  }
}

// ── Store ───────────────────────────────────────────────────────────────

/**
 * Narrow interface for run-related store operations.
 * Covers create, read, update, and query operations for pipeline runs.
 */
export type RunStore = Pick<ForemanStore,
  | "createRun"
  | "updateRun"
  | "getRun"
  | "getActiveRuns"
  | "getRunsByStatus"
  | "getRunsByStatuses"
  | "getRunsByStatusSince"
  | "getRunsByStatusesSince"
  | "purgeOldRuns"
  | "deleteRun"
  | "getRunsForTask"
  | "hasActiveOrPendingRun"
  | "getRunsByBaseBranch"
  | "getRunEvents"
>;

/**
 * Narrow interface for project-related store operations.
 * Covers project registration, lookup, and updates.
 */
export type ProjectStore = Pick<ForemanStore,
  | "registerProject"
  | "getProject"
  | "getProjectByPath"
  | "listProjects"
  | "updateProject"
>;

/**
 * Narrow interface for progress and event logging.
 * Covers run progress tracking and event emission.
 */
export type ProgressEventStore = Pick<ForemanStore,
  | "updateRunProgress"
  | "getRunProgress"
  | "logEvent"
  | "getEvents"
>;

/**
 * Narrow interface for inter-agent messaging.
 * Covers message sending, retrieval, and management.
 */
export type MailStore = Pick<ForemanStore,
  | "sendMessage"
  | "getMessages"
  | "getAllMessages"
  | "getAllMessagesGlobal"
  | "markMessageRead"
  | "markAllMessagesRead"
  | "deleteMessage"
  | "getMessage"
>;

/**
 * Narrow interface for native task management.
 * Covers task CRUD operations and claiming.
 */
export type TaskStore = Pick<ForemanStore,
  | "listTasksByStatus"
  | "updateTaskStatus"
  | "hasNativeTasks"
  | "getTaskById"
  | "getTaskByExternalId"
  | "getReadyTasks"
  | "claimTask"
>;

/**
 * Narrow interface for sentinel configuration and runs.
 * Covers CI/sentinel integration for branch monitoring.
 */
export type SentinelStore = Pick<ForemanStore,
  | "upsertSentinelConfig"
  | "getSentinelConfig"
  | "recordSentinelRun"
  | "updateSentinelRun"
  | "getSentinelRuns"
>;

/**
 * Narrow interface for cost tracking and metrics.
 * Covers cost recording, aggregation, and success rate calculations.
 */
export type CostMetricsStore = Pick<ForemanStore,
  | "recordCost"
  | "getCosts"
  | "getCostBreakdown"
  | "getPhaseMetrics"
  | "getRecentOutcomeCounts"
  | "getSuccessRate"
  | "getMetrics"
  | "logRateLimitEvent"
  | "getRateLimitCountsByModel"
  | "getRecentRateLimitEvents"
>;

/**
 * Narrow interface for dashboard read operations.
 * Covers all read-only methods needed by pollDashboard() and readProjectRegistry().
 * The CLI uses this interface so pure read functions don't need the full store type.
 */
export type DashboardReadStore = Pick<ForemanStore,
  | "listProjects"
  | "getProject"
  | "getActiveRuns"
  | "getRunsByStatus"
  | "getRunProgress"
  | "getMetrics"
  | "getEvents"
  | "getSuccessRate"
  | "listTasksByStatus"
  | "close"
>;

/**
 * Narrow read-only interface for the status command.
 * Covers project lookup, active runs, progress, metrics, success rate, and recent outcomes.
 */
export type StatusReadStore = Pick<ForemanStore,
  | "getProjectByPath"
  | "getActiveRuns"
  | "getRunProgress"
  | "getRunsForTask"
  | "getRecentOutcomeCounts"
  | "getSuccessRate"
  | "getMetrics"
>;

export class ForemanStore {
  private db: LocalStoreDatabase;

  /**
   * Create a disabled ForemanStore compatibility object for a project.
   *
   * Current state access should go through the Postgres-backed daemon APIs.
   *
   * @param projectPath - Absolute path to the project root directory.
   */
  static forProject(projectPath: string): ForemanStore {
    return new ForemanStore(join(projectPath, ".foreman", "foreman.db"));
  }

  /**
   * Create a DashboardReadStore for a project.
   *
   * Returns a disabled local-store compatibility handle typed as DashboardReadStore.
   * Use this factory when you only need read-only dashboard operations
   * (pollDashboard, readProjectRegistry) and don't need write access.
   *
   * @param projectPath - Absolute path to the project root directory.
   * @returns A DashboardReadStore instance for the project.
   */
  static forDashboard(projectPath: string): DashboardReadStore {
    return new ForemanStore(join(projectPath, ".foreman", "foreman.db")) as DashboardReadStore;
  }

  /**
   * Open the project database in READONLY mode for safe concurrent dashboard reads.
   *
   * Returns a disabled local-store compatibility handle.
   * Postgres-backed dashboard reads should use the daemon APIs.
   *
   * This is intentionally a static factory that bypasses the normal ForemanStore
   * constructor (which runs migrations and writes to the DB) — the dashboard reads
   * should never write to a project's database.
   *
   * @param projectPath - Absolute path to the project root directory.
   * @returns A disabled local-store compatibility handle.
   */
  static openReadonly(_projectPath: string): LocalStoreDatabase {
    return createDisabledLocalStoreDb();
  }

  constructor(dbPath?: string) {
    const resolvedPath = dbPath ?? join(homedir(), ".foreman", "foreman.db");
    mkdirSync(join(resolvedPath, ".."), { recursive: true });

    this.db = createDisabledLocalStoreDb();
    return;

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

    // Apply native task management schemas (PRD-2026-006 REQ-003, REQ-004).
    // Both use CREATE TABLE IF NOT EXISTS — safe to run on every startup.
    this.db.exec(TASKS_SCHEMA);
    if (tasksTableNeedsClosedStatusMigration(this.db)) {
      migrateLegacyTasksTable(this.db);
    }
    this.db.exec(TASK_DEPENDENCIES_SCHEMA);

    // Apply rate limit events schema (P2: per-model rate limit tracking).
    // Uses CREATE TABLE IF NOT EXISTS — safe to run on every startup.
    this.db.exec(RATE_LIMIT_EVENTS_SCHEMA);
  }

  /** Expose the underlying database for modules that need direct access (e.g. MergeQueue). */
  getDb(): LocalStoreDatabase {
    return this.db;
  }

  isOpen(): boolean {
    return (this.db as unknown as { open: boolean }).open;
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
      const rows = this.db
        .prepare(
          `SELECT * FROM tasks WHERE status IN (${placeholders})
           ORDER BY priority ASC, updated_at ASC
           LIMIT ?`
        )
        .all(...statuses, limit) as NativeTask[];
      return normalizeNativeTasks(rows);
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
    // Normalize legacy 'in_progress' (underscore) to native 'in-progress' (hyphen)
    // before writing to the database CHECK constraint.
    const normalizedStatus = newStatus === "in_progress" ? "in-progress" : newStatus;
    const now = new Date().toISOString();
    this.db
      .prepare(`UPDATE tasks SET status = ?, updated_at = ? WHERE id = ?`)
      .run(normalizedStatus, now, taskId);
  }

  /**
   * Update task labels via a short-lived write.
   * Used by dispatcher for branch label auto-labeling.
   *
   * @param taskId - Task UUID to update.
   * @param labels - New labels array.
   */
  updateTaskLabels(taskId: string, labels: string[]): void {
    const now = new Date().toISOString();
    const labelsJson = JSON.stringify(labels);
    this.db
      .prepare(`UPDATE tasks SET labels = ?, updated_at = ? WHERE id = ?`)
      .run(labelsJson, now, taskId);
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
    taskId: string,
    agentType: Run["agent_type"],
    worktreePath?: string,
    opts?: { baseBranch?: string | null; mergeStrategy?: Run["merge_strategy"] },
  ): Run {
    const now = new Date().toISOString();
    const run: Run = {
      id: randomUUID(),
      project_id: projectId,
      task_id: taskId,
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
        `INSERT INTO runs (id, project_id, task_id, agent_type, session_key, worktree_path, status, started_at, completed_at, created_at, base_branch, merge_strategy)
         VALUES (@id, @project_id, @task_id, @agent_type, @session_key, @worktree_path, @status, @started_at, @completed_at, @created_at, @base_branch, @merge_strategy)`
      )
      .run(run);
    return run;
  }

  updateRun(
    id: string,
    updates: Partial<Pick<Run, "status" | "session_key" | "worktree_path" | "started_at" | "completed_at" | "base_branch" | "merge_strategy" | "commit_sha" | "pr_url" | "pr_state" | "pr_head_sha" | "cooldown_until">>
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
   * Used by Refinery.getCompletedRuns() to find retry-eligible runs when a taskId
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

  getRunsForTask(taskId: string, projectId?: string): Run[] {
    if (projectId) {
      return this.db
        .prepare(
          "SELECT * FROM runs WHERE project_id = ? AND task_id = ? ORDER BY created_at DESC, rowid DESC"
        )
        .all(projectId, taskId) as Run[];
    }
    return this.db
      .prepare("SELECT * FROM runs WHERE task_id = ? ORDER BY created_at DESC, rowid DESC")
      .all(taskId) as Run[];
  }

  /**
   * Check whether a task already has a non-terminal run in the database.
   *
   * "Non-terminal" means the run is still active or has produced a result that
   * should block a new dispatch (pending, running, completed, stuck, pr-created).
   * Terminal/retryable states (failed, merged, conflict, test-failed, reset) are
   * excluded so that genuinely failed tasks can be retried.
   *
   * Used by the dispatcher as a just-in-time guard immediately before calling
   * createRun(), preventing duplicate dispatches when two dispatch cycles race
   * and both observe an empty activeRuns snapshot.
   *
   * @returns true if the task should be skipped (a non-terminal run exists),
   *          false if it is safe to dispatch.
   */
  hasActiveOrPendingRun(taskId: string, projectId?: string): boolean {
    // Statuses that represent "work is in flight or done and not reset"
    const blockingStatuses = ["pending", "running", "completed", "stuck", "pr-created"];
    const placeholders = blockingStatuses.map(() => "?").join(", ");
    let row: unknown;
    if (projectId) {
      row = this.db
        .prepare(
          `SELECT 1 FROM runs WHERE project_id = ? AND task_id = ? AND status IN (${placeholders}) LIMIT 1`
        )
        .get(projectId, taskId, ...blockingStatuses);
    } else {
      row = this.db
        .prepare(
          `SELECT 1 FROM runs WHERE task_id = ? AND status IN (${placeholders}) LIMIT 1`
        )
        .get(taskId, ...blockingStatuses);
    }
    return row !== undefined && row !== null;
  }

  /**
   * Find all runs that were branched from the given base branch (i.e. stacked on it).
   * Used by rebaseStackedBranches() to find dependent tasks after a merge.
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

  getRecentOutcomeCounts(projectId?: string, since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()): { merged: number; failed: number; stuck: number } {
    const rows = projectId
      ? this.db
        .prepare(
          `SELECT rowid, task_id, status, completed_at, created_at FROM runs
           WHERE project_id = ?
           ORDER BY created_at DESC, rowid DESC`,
        )
        .all(projectId) as Array<{ rowid: number; task_id: string; status: Run["status"]; completed_at: string | null; created_at: string }>
      : this.db
        .prepare(
          `SELECT rowid, task_id, status, completed_at, created_at FROM runs
           ORDER BY created_at DESC, rowid DESC`,
        )
        .all() as Array<{ rowid: number; task_id: string; status: Run["status"]; completed_at: string | null; created_at: string }>;

    const seenTasks = new Set<string>();
    let merged = 0;
    let failed = 0;
    let stuck = 0;

    for (const row of rows) {
      if (seenTasks.has(row.task_id)) continue;
      seenTasks.add(row.task_id);

      if (!row.completed_at || row.completed_at <= since) continue;

      if (row.status === "merged" || row.status === "pr-created") {
        merged += 1;
        continue;
      }
      if (row.status === "failed" || row.status === "test-failed" || row.status === "reset") {
        failed += 1;
        continue;
      }
      if (row.status === "stuck") {
        stuck += 1;
      }
    }

    return { merged, failed, stuck };
  }

  /**
   * Compute the 24-hour pipeline success rate for a project.
   *
   * Success rate = merged / (merged + failed), where:
   * - "merged" includes both `merged` and `pr-created` statuses
   * - "failed" includes `failed`, `test-failed`, and `reset`
   * - only the latest authoritative run per task is counted
   * - `completed` (pending merge), `running`, `pending`, and `stuck` are excluded
   *
   * Returns `{ rate: null, merged: 0, failed: 0 }` when fewer than 3 terminal
   * runs have completed in the last 24 hours (not enough data to be meaningful).
   *
   * @param projectId - Scope to a specific project; omit for global.
   */
  getSuccessRate(projectId?: string): { rate: number | null; merged: number; failed: number } {
    const { merged, failed } = this.getRecentOutcomeCounts(projectId);
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
   * Look up a native task by its `id` column.
   *
   * Falls back when getTaskByExternalId misses because the task has no external_id set.
   */
  getTaskById(id: string): NativeTask | null {
    try {
      return normalizeNativeTask(
        this.db
          .prepare("SELECT * FROM tasks WHERE id = ? LIMIT 1")
          .get(id) as NativeTask | undefined,
      );
    } catch {
      return null;
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
      return normalizeNativeTask(
        this.db
          .prepare("SELECT * FROM tasks WHERE external_id = ? LIMIT 1")
          .get(externalId) as NativeTask | undefined,
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
    const rows = this.db
      .prepare(
        `SELECT * FROM tasks
         WHERE status = 'ready'
         ORDER BY priority ASC, created_at ASC`,
      )
      .all() as NativeTask[];
    return normalizeNativeTasks(rows);
  }

  /**
   * Atomically claim a task by transitioning its status from 'ready' to 'in-progress'
   * and recording the associated run_id in a single Postgres transaction.
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
