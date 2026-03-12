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
}

export interface Metrics {
  totalCost: number;
  totalTokens: number;
  tasksByStatus: Record<string, number>;
  costByRuntime: Array<{ run_id: string; cost: number; duration_seconds: number | null }>;
}

// ── Memory interfaces ───────────────────────────────────────────────────

export interface Episode {
  id: string;
  run_id: string | null;
  project_id: string;
  seed_id: string;
  task_title: string;
  task_description: string | null;
  role: string;
  outcome: "success" | "failure";
  duration_ms: number | null;
  cost_usd: number;
  key_learnings: string | null;
  created_at: string;
}

export interface Pattern {
  id: string;
  project_id: string;
  pattern_type: string;
  pattern_description: string;
  success_count: number;
  failure_count: number;
  first_seen: string;
  last_used: string;
  created_at: string;
}

export interface Skill {
  id: string;
  project_id: string;
  skill_name: string;
  skill_description: string;
  applicable_to_roles: string; // JSON array string
  success_examples: string | null; // JSON string
  confidence_score: number;
  created_at: string;
}

export interface AgentMemory {
  episodes: Episode[];
  patterns: Pattern[];
  skills: Skill[];
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

CREATE TABLE IF NOT EXISTS episodes (
  id TEXT PRIMARY KEY,
  run_id TEXT,
  project_id TEXT NOT NULL,
  seed_id TEXT NOT NULL,
  task_title TEXT NOT NULL,
  task_description TEXT,
  role TEXT NOT NULL,
  outcome TEXT NOT NULL,
  duration_ms INTEGER,
  cost_usd REAL DEFAULT 0.0,
  key_learnings TEXT,
  created_at TEXT,
  FOREIGN KEY (project_id) REFERENCES projects(id)
);

CREATE TABLE IF NOT EXISTS patterns (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  pattern_type TEXT NOT NULL,
  pattern_description TEXT NOT NULL,
  success_count INTEGER DEFAULT 0,
  failure_count INTEGER DEFAULT 0,
  first_seen TEXT,
  last_used TEXT,
  created_at TEXT,
  FOREIGN KEY (project_id) REFERENCES projects(id)
);

CREATE TABLE IF NOT EXISTS skills (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  skill_name TEXT NOT NULL,
  skill_description TEXT NOT NULL,
  applicable_to_roles TEXT DEFAULT '[]',
  success_examples TEXT,
  confidence_score REAL DEFAULT 0,
  created_at TEXT,
  FOREIGN KEY (project_id) REFERENCES projects(id)
);

-- Indices for memory table queries (episodes accumulate over time)
CREATE INDEX IF NOT EXISTS idx_episodes_project_created ON episodes(project_id, created_at);
CREATE INDEX IF NOT EXISTS idx_episodes_seed_role ON episodes(project_id, seed_id, role);
CREATE INDEX IF NOT EXISTS idx_patterns_project_success ON patterns(project_id, success_count);
CREATE INDEX IF NOT EXISTS idx_skills_project_confidence ON skills(project_id, confidence_score);
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

    return {
      totalCost: totals.totalCost,
      totalTokens: totals.totalTokens,
      tasksByStatus,
      costByRuntime,
    };
  }

  // ── Memory: Episodes ─────────────────────────────────────────────────

  storeEpisode(
    projectId: string,
    runId: string | null,
    seedId: string,
    taskTitle: string,
    taskDescription: string | null,
    role: string,
    outcome: "success" | "failure",
    costUsd: number,
    durationMs?: number,
    keyLearnings?: string,
  ): Episode {
    const now = new Date().toISOString();
    const episode: Episode = {
      id: randomUUID(),
      run_id: runId,
      project_id: projectId,
      seed_id: seedId,
      task_title: taskTitle,
      task_description: taskDescription ?? null,
      role,
      outcome,
      duration_ms: durationMs ?? null,
      cost_usd: costUsd,
      key_learnings: keyLearnings ?? null,
      created_at: now,
    };
    this.db
      .prepare(
        `INSERT INTO episodes (id, run_id, project_id, seed_id, task_title, task_description, role, outcome, duration_ms, cost_usd, key_learnings, created_at)
         VALUES (@id, @run_id, @project_id, @seed_id, @task_title, @task_description, @role, @outcome, @duration_ms, @cost_usd, @key_learnings, @created_at)`,
      )
      .run(episode);
    return episode;
  }

  getRelevantEpisodes(
    projectId: string,
    seedId?: string,
    role?: string,
    limit = 5,
  ): Episode[] {
    const conditions: string[] = ["project_id = ?"];
    const params: unknown[] = [projectId];
    if (seedId) {
      conditions.push("seed_id = ?");
      params.push(seedId);
    }
    if (role) {
      conditions.push("role = ?");
      params.push(role);
    }
    params.push(limit);
    return this.db
      .prepare(
        `SELECT * FROM episodes WHERE ${conditions.join(" AND ")} ORDER BY created_at DESC, rowid DESC LIMIT ?`,
      )
      .all(...params) as Episode[];
  }

  // ── Memory: Patterns ─────────────────────────────────────────────────

  storePattern(
    projectId: string,
    patternType: string,
    patternDescription: string,
    outcome: "success" | "failure",
  ): Pattern {
    const now = new Date().toISOString();
    // Upsert: increment counts on existing pattern, insert if new
    const existing = this.db
      .prepare(
        `SELECT * FROM patterns WHERE project_id = ? AND pattern_type = ? AND pattern_description = ?`,
      )
      .get(projectId, patternType, patternDescription) as Pattern | undefined;

    if (existing) {
      if (outcome === "success") {
        this.db
          .prepare(`UPDATE patterns SET success_count = success_count + 1, last_used = ? WHERE id = ?`)
          .run(now, existing.id);
      } else {
        this.db
          .prepare(`UPDATE patterns SET failure_count = failure_count + 1, last_used = ? WHERE id = ?`)
          .run(now, existing.id);
      }
      return this.db
        .prepare(`SELECT * FROM patterns WHERE id = ?`)
        .get(existing.id) as Pattern;
    }

    const pattern: Pattern = {
      id: randomUUID(),
      project_id: projectId,
      pattern_type: patternType,
      pattern_description: patternDescription,
      success_count: outcome === "success" ? 1 : 0,
      failure_count: outcome === "failure" ? 1 : 0,
      first_seen: now,
      last_used: now,
      created_at: now,
    };
    this.db
      .prepare(
        `INSERT INTO patterns (id, project_id, pattern_type, pattern_description, success_count, failure_count, first_seen, last_used, created_at)
         VALUES (@id, @project_id, @pattern_type, @pattern_description, @success_count, @failure_count, @first_seen, @last_used, @created_at)`,
      )
      .run(pattern);
    return pattern;
  }

  getPatterns(projectId: string, patternType?: string, minSuccessCount = 0): Pattern[] {
    if (patternType) {
      return this.db
        .prepare(
          `SELECT * FROM patterns WHERE project_id = ? AND pattern_type = ? AND success_count >= ? ORDER BY success_count DESC`,
        )
        .all(projectId, patternType, minSuccessCount) as Pattern[];
    }
    return this.db
      .prepare(
        `SELECT * FROM patterns WHERE project_id = ? AND success_count >= ? ORDER BY success_count DESC`,
      )
      .all(projectId, minSuccessCount) as Pattern[];
  }

  // ── Memory: Skills ───────────────────────────────────────────────────

  storeSkill(
    projectId: string,
    skillName: string,
    skillDescription: string,
    roles: string[],
    successExamples?: string[],
    confidence = 50,
  ): Skill {
    const now = new Date().toISOString();
    const skill: Skill = {
      id: randomUUID(),
      project_id: projectId,
      skill_name: skillName,
      skill_description: skillDescription,
      applicable_to_roles: JSON.stringify(roles),
      success_examples: successExamples ? JSON.stringify(successExamples) : null,
      confidence_score: confidence,
      created_at: now,
    };
    this.db
      .prepare(
        `INSERT INTO skills (id, project_id, skill_name, skill_description, applicable_to_roles, success_examples, confidence_score, created_at)
         VALUES (@id, @project_id, @skill_name, @skill_description, @applicable_to_roles, @success_examples, @confidence_score, @created_at)`,
      )
      .run(skill);
    return skill;
  }

  getSkills(projectId: string, role?: string): Skill[] {
    if (role) {
      // Safe: role comes from the AgentRole union type ("lead"|"explorer"|"developer"|"qa"|"reviewer"|"worker"),
      // none of which contain SQL LIKE wildcard characters (% or _). Do not pass user-controlled strings here.
      return this.db
        .prepare(
          `SELECT * FROM skills WHERE project_id = ? AND applicable_to_roles LIKE ? ORDER BY confidence_score DESC`,
        )
        .all(projectId, `%"${role}"%`) as Skill[];
    }
    return this.db
      .prepare(
        `SELECT * FROM skills WHERE project_id = ? ORDER BY confidence_score DESC`,
      )
      .all(projectId) as Skill[];
  }

  // ── Memory: Combined query ───────────────────────────────────────────

  queryMemory(projectId: string, seedId?: string, role?: string): AgentMemory {
    const episodes = this.getRelevantEpisodes(projectId, seedId, role, 5);
    // Only surface patterns confirmed successful at least once
    const patterns = this.getPatterns(projectId, undefined, 1);
    const skills = this.getSkills(projectId, role);
    return { episodes, patterns, skills };
  }
}
