import Database from "better-sqlite3";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { randomUUID } from "node:crypto";

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
  status: "pending" | "running" | "completed" | "failed" | "stuck" | "merged" | "conflict" | "test-failed" | "pr-created";
  started_at: string | null;
  completed_at: string | null;
  created_at: string;
  progress: string | null;
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
  | "pr-created";

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
}

export interface Metrics {
  totalCost: number;
  totalTokens: number;
  tasksByStatus: Record<string, number>;
  costByRuntime: Array<{ run_id: string; cost: number; duration_seconds: number | null }>;
  costByPhase?: Record<string, number>;      // aggregated cost per pipeline phase
  agentCostBreakdown?: Record<string, number>; // aggregated cost per model/agent type
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
`;

// Add progress column to runs table if not present (migration)
const MIGRATIONS = [
  `ALTER TABLE runs ADD COLUMN progress TEXT DEFAULT NULL`,
  `ALTER TABLE runs RENAME COLUMN bead_id TO seed_id`,
];

// ── Store ───────────────────────────────────────────────────────────────

export class ForemanStore {
  private db: Database.Database;

  constructor(dbPath?: string) {
    const resolvedPath = dbPath ?? join(homedir(), ".foreman", "foreman.db");
    mkdirSync(join(resolvedPath, ".."), { recursive: true });

    this.db = new Database(resolvedPath);
    this.db.pragma("journal_mode = WAL");
    this.db.pragma("foreign_keys = ON");
    this.db.exec(SCHEMA);

    // Run idempotent migrations
    for (const sql of MIGRATIONS) {
      try {
        this.db.exec(sql);
      } catch {
        // Column/table already exists — safe to ignore
      }
    }
  }

  close(): void {
    this.db.close();
  }

  // ── Projects ────────────────────────────────────────────────────────

  registerProject(name: string, path: string): Project {
    const now = new Date().toISOString();
    const project: Project = {
      id: randomUUID(),
      name,
      path,
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
    return (
      (this.db
        .prepare("SELECT * FROM projects WHERE path = ?")
        .get(path) as Project | undefined) ?? null
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
    worktreePath?: string
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
    };
    this.db
      .prepare(
        `INSERT INTO runs (id, project_id, seed_id, agent_type, session_key, worktree_path, status, started_at, completed_at, created_at)
         VALUES (@id, @project_id, @seed_id, @agent_type, @session_key, @worktree_path, @status, @started_at, @completed_at, @created_at)`
      )
      .run(run);
    return run;
  }

  updateRun(
    id: string,
    updates: Partial<Pick<Run, "status" | "session_key" | "worktree_path" | "started_at" | "completed_at">>
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
}
