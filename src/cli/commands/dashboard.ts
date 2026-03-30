import { Command } from "commander";
import chalk from "chalk";
import { existsSync } from "node:fs";
import { join } from "node:path";
import Database from "better-sqlite3";
import {
  ForemanStore,
  type Project,
  type Run,
  type RunProgress,
  type Metrics,
  type Event,
  type NativeTask,
} from "../../lib/store.js";
import { elapsed, renderAgentCard, formatSuccessRate } from "../watch-ui.js";
import { BeadsRustClient } from "../../lib/beads-rust.js";
import type { BrIssue } from "../../lib/beads-rust.js";
import type { Issue } from "../../lib/task-client.js";
import { loadDashboardConfig } from "../../lib/project-config.js";

// ── Task count helpers (for --simple mode) ───────────────────────────────

/**
 * Task counts fetched from the br backend for display in dashboard --simple.
 */
export interface DashboardTaskCounts {
  total: number;
  ready: number;
  inProgress: number;
  completed: number;
  blocked: number;
}

/**
 * Fetch br task counts for the compact status view (used by --simple mode).
 * Returns zeros if br is not initialized or binary is missing.
 */
export async function fetchDashboardTaskCounts(projectPath: string): Promise<DashboardTaskCounts> {
  const brClient = new BeadsRustClient(projectPath);

  let openIssues: BrIssue[] = [];
  try { openIssues = await brClient.list(); } catch { /* br not available */ }

  let closedIssues: BrIssue[] = [];
  try { closedIssues = await brClient.list({ status: "closed" }); } catch { /* no closed */ }

  let readyIssues: Issue[] = [];
  try { readyIssues = await brClient.ready(); } catch { /* br ready failed */ }

  const inProgress = openIssues.filter((i) => i.status === "in_progress").length;
  const completed = closedIssues.length;
  const readyIds = new Set(readyIssues.map((i) => i.id));
  const ready = readyIssues.length;
  const blocked = openIssues.filter(
    (i) => i.status !== "in_progress" && !readyIds.has(i.id),
  ).length;
  const total = openIssues.length + completed;

  return { total, ready, inProgress, completed, blocked };
}

// ── Types ─────────────────────────────────────────────────────────────────

/** Snapshot of a single project collected via READONLY DB connection. */
export interface ProjectSnapshot {
  project: Project;
  activeRuns: Run[];
  completedRuns: Run[];
  progresses: Map<string, RunProgress | null>;
  metrics: Metrics;
  events: Event[];
  successRate: { rate: number | null; merged: number; failed: number };
  /** Tasks requiring human attention (conflict/failed/stuck/backlog). */
  needsHumanTasks: NativeTask[];
  /** Whether the project DB was inaccessible during snapshot. */
  offline: boolean;
}

export interface DashboardState {
  projects: Project[];
  activeRuns: Map<string, Run[]>;
  completedRuns: Map<string, Run[]>;
  progresses: Map<string, RunProgress | null>;
  metrics: Map<string, Metrics>;
  events: Map<string, Event[]>;
  lastUpdated: Date;
  /** 24-hour success rate stats per project ID. rate=null means insufficient data. Optional for backward compat. */
  successRates?: Map<string, { rate: number | null; merged: number; failed: number }>;
  /** Cross-project "needs human" tasks (REQ-011). */
  needsHumanTasks?: NativeTask[];
  /** Whether each project is reachable (true = offline / DB inaccessible). */
  offlineProjects?: Set<string>;
}

// ── Needs Human statuses (REQ-011) ────────────────────────────────────────

/** Statuses that require human operator attention. */
export const NEEDS_HUMAN_STATUSES = ["conflict", "failed", "stuck", "backlog"] as const;
export type NeedsHumanStatus = typeof NEEDS_HUMAN_STATUSES[number];

/** Sort order for "needs human" status grouping (lower index = higher urgency). */
const STATUS_SORT_ORDER: Record<string, number> = {
  conflict: 0,
  failed: 1,
  stuck: 2,
  backlog: 3,
};

/**
 * Sort tasks by: (1) status urgency, (2) priority (P0 first), (3) age (oldest first).
 * Satisfies REQ-011.1.
 */
export function sortNeedsHumanTasks(tasks: NativeTask[]): NativeTask[] {
  return [...tasks].sort((a, b) => {
    // Primary: status urgency (conflict > failed > stuck > backlog)
    const statusA = STATUS_SORT_ORDER[a.status] ?? 99;
    const statusB = STATUS_SORT_ORDER[b.status] ?? 99;
    if (statusA !== statusB) return statusA - statusB;

    // Secondary: priority (P0=0 first, ascending)
    if (a.priority !== b.priority) return a.priority - b.priority;

    // Tertiary: age (oldest updated_at first)
    return new Date(a.updated_at).getTime() - new Date(b.updated_at).getTime();
  });
}

// ── Project Registry ─────────────────────────────────────────────────────

/**
 * A registered project entry as stored in the global project registry.
 * Used by multi-project dashboard aggregation.
 */
export interface RegisteredProject {
  id: string;
  name: string;
  path: string;
}

/**
 * Read the list of all registered projects from the current project's DB.
 *
 * Falls back to returning only the current working directory's project if the
 * DB doesn't have multiple registered projects (REQ-010 fallback).
 *
 * @param store - ForemanStore for the current project (already open, read-write).
 * @returns Array of projects to include in the multi-project dashboard.
 */
export function readProjectRegistry(store: ForemanStore): RegisteredProject[] {
  const projects = store.listProjects();
  return projects.map((p) => ({ id: p.id, name: p.name, path: p.path }));
}

// ── READONLY snapshot helpers ─────────────────────────────────────────────

/**
 * Read a single project's snapshot from its database using a READONLY connection.
 * Returns an "offline" snapshot if the DB is inaccessible.
 *
 * @param project    - Project metadata (id, name, path).
 * @param eventsLimit - Max events to fetch.
 */
function readProjectDbSnapshot(
  project: RegisteredProject,
  eventsLimit: number,
): ProjectSnapshot {
  const dbPath = join(project.path, ".foreman", "foreman.db");

  // Return offline indicator if DB file doesn't exist
  if (!existsSync(dbPath)) {
    return makeOfflineSnapshot(project);
  }

  let db: Database.Database | null = null;
  try {
    db = ForemanStore.openReadonly(project.path);

    // ── Active runs ─────────────────────────────────────────────────
    const activeRuns = (db.prepare(
      `SELECT * FROM runs WHERE project_id = ? AND status IN ('pending', 'running') ORDER BY created_at DESC`
    ).all(project.id) as Run[]);

    // ── Completed runs (last 5) ──────────────────────────────────────
    const completedRuns = (db.prepare(
      `SELECT * FROM runs WHERE project_id = ? AND status = 'completed' ORDER BY completed_at DESC LIMIT 5`
    ).all(project.id) as Run[]);

    // ── Progresses ──────────────────────────────────────────────────
    const progresses = new Map<string, RunProgress | null>();
    for (const run of [...activeRuns, ...completedRuns]) {
      if (!progresses.has(run.id)) {
        const progress = run.progress ? (JSON.parse(run.progress) as RunProgress) : null;
        progresses.set(run.id, progress);
      }
    }

    // ── Metrics ────────────────────────────────────────────────────
    const totalCostRow = db.prepare(
      `SELECT COALESCE(SUM(c.estimated_cost), 0) AS total_cost,
              COALESCE(SUM(c.tokens_in + c.tokens_out), 0) AS total_tokens
       FROM costs c
       JOIN runs r ON r.id = c.run_id
       WHERE r.project_id = ?`
    ).get(project.id) as { total_cost: number; total_tokens: number } | undefined;

    const taskStatusRows = (db.prepare(
      `SELECT r.status, COUNT(*) as count FROM runs r WHERE r.project_id = ? GROUP BY r.status`
    ).all(project.id) as Array<{ status: string; count: number }>);

    const tasksByStatus: Record<string, number> = {};
    for (const row of taskStatusRows) {
      tasksByStatus[row.status] = row.count;
    }

    const metrics: Metrics = {
      totalCost: totalCostRow?.total_cost ?? 0,
      totalTokens: totalCostRow?.total_tokens ?? 0,
      tasksByStatus,
      costByRuntime: [],
    };

    // ── Events ─────────────────────────────────────────────────────
    const events = (db.prepare(
      `SELECT * FROM events WHERE project_id = ? ORDER BY created_at DESC LIMIT ?`
    ).all(project.id, eventsLimit) as Event[]);

    // ── Success rate (last 24h) ─────────────────────────────────────
    const since24h = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
    const srRow = db.prepare(
      `SELECT
         SUM(CASE WHEN status = 'merged' THEN 1 ELSE 0 END) AS merged,
         SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) AS failed
       FROM runs
       WHERE project_id = ? AND completed_at >= ?`
    ).get(project.id, since24h) as { merged: number; failed: number } | undefined;

    const merged = srRow?.merged ?? 0;
    const failed = srRow?.failed ?? 0;
    const total = merged + failed;
    const rate: number | null = total >= 3 ? merged / total : null;

    // ── Needs Human tasks ───────────────────────────────────────────
    let needsHumanTasks: NativeTask[] = [];
    try {
      const placeholders = NEEDS_HUMAN_STATUSES.map(() => "?").join(", ");
      needsHumanTasks = (db.prepare(
        `SELECT * FROM tasks WHERE status IN (${placeholders})
         ORDER BY priority ASC, updated_at ASC
         LIMIT 200`
      ).all(...NEEDS_HUMAN_STATUSES) as NativeTask[]).map((t) => ({
        ...t,
        projectName: project.name,
        projectId: project.id,
        projectPath: project.path,
      }));
    } catch {
      // tasks table may not exist in older project DBs — not an error
    }

    return {
      project: {
        id: project.id,
        name: project.name,
        path: project.path,
        status: "active",
        created_at: "",
        updated_at: "",
      },
      activeRuns,
      completedRuns,
      progresses,
      metrics,
      events,
      successRate: { rate, merged, failed },
      needsHumanTasks,
      offline: false,
    };
  } catch {
    return makeOfflineSnapshot(project);
  } finally {
    try { db?.close(); } catch { /* ignore */ }
  }
}

function makeOfflineSnapshot(project: RegisteredProject): ProjectSnapshot {
  return {
    project: {
      id: project.id,
      name: project.name,
      path: project.path,
      status: "active",
      created_at: "",
      updated_at: "",
    },
    activeRuns: [],
    completedRuns: [],
    progresses: new Map(),
    metrics: { totalCost: 0, totalTokens: 0, tasksByStatus: {}, costByRuntime: [] },
    events: [],
    successRate: { rate: null, merged: 0, failed: 0 },
    needsHumanTasks: [],
    offline: true,
  };
}

/**
 * Read snapshots from multiple project databases concurrently using READONLY
 * connections via `Promise.all()`.  Satisfies REQ-010 and REQ-019.
 *
 * Projects whose databases are inaccessible return an offline snapshot rather
 * than crashing the dashboard (REQ-010.1).
 *
 * @param projects    - Array of registered projects.
 * @param eventsLimit - Max events per project (default: 8).
 */
export async function readProjectSnapshot(
  projects: RegisteredProject[],
  eventsLimit = 8,
): Promise<ProjectSnapshot[]> {
  // Run all reads concurrently for performance (REQ-019)
  return Promise.all(
    projects.map((project) =>
      // Wrap in a Promise so better-sqlite3 sync calls don't block the event loop
      // and so errors are captured per-project rather than aborting all reads.
      Promise.resolve().then(() => readProjectDbSnapshot(project, eventsLimit))
    )
  );
}

/**
 * Aggregate ProjectSnapshot[] into a DashboardState (for renderDashboard compatibility).
 */
export function aggregateSnapshots(snapshots: ProjectSnapshot[]): DashboardState {
  const projects: Project[] = [];
  const activeRuns = new Map<string, Run[]>();
  const completedRuns = new Map<string, Run[]>();
  const progresses = new Map<string, RunProgress | null>();
  const metrics = new Map<string, Metrics>();
  const events = new Map<string, Event[]>();
  const successRates = new Map<string, { rate: number | null; merged: number; failed: number }>();
  const allNeedsHuman: NativeTask[] = [];
  const offlineProjects = new Set<string>();

  for (const snap of snapshots) {
    projects.push(snap.project);
    if (snap.offline) {
      offlineProjects.add(snap.project.id);
    }
    activeRuns.set(snap.project.id, snap.activeRuns);
    completedRuns.set(snap.project.id, snap.completedRuns);
    for (const [k, v] of snap.progresses) {
      progresses.set(k, v);
    }
    metrics.set(snap.project.id, snap.metrics);
    events.set(snap.project.id, snap.events);
    successRates.set(snap.project.id, snap.successRate);
    for (const task of snap.needsHumanTasks) {
      allNeedsHuman.push(task);
    }
  }

  return {
    projects,
    activeRuns,
    completedRuns,
    progresses,
    metrics,
    events,
    lastUpdated: new Date(),
    successRates,
    needsHumanTasks: sortNeedsHumanTasks(allNeedsHuman),
    offlineProjects,
  };
}

// ── Event icons ──────────────────────────────────────────────────────────

const EVENT_ICONS: Record<string, string> = {
  dispatch: "⬇",
  claim: "→",
  complete: "✓",
  fail: "✗",
  stuck: "⚠",
  restart: "↺",
  recover: "⚡",
  merge: "⊕",
  conflict: "⊘",
  "test-fail": "⊘",
  "pr-created": "↑",
};

const RULE = chalk.dim("─".repeat(60));
const THICK_RULE = chalk.dim("━".repeat(60));

// ── Status color helpers ──────────────────────────────────────────────────

type ChalkColor = (text: string) => string;
function taskStatusColor(status: string): ChalkColor {
  switch (status) {
    case "conflict": return chalk.bgRed.white;
    case "failed":   return chalk.red;
    case "stuck":    return chalk.yellow;
    case "backlog":  return chalk.dim;
    default:         return chalk.white;
  }
}

// ── Pure display functions ────────────────────────────────────────────────

/**
 * Format a single event as a compact timeline line.
 */
export function renderEventLine(event: Event): string {
  const icon = EVENT_ICONS[event.event_type] ?? "•";
  const age = elapsed(event.created_at);

  let detail = "";
  if (event.details) {
    try {
      const parsed = JSON.parse(event.details) as Record<string, unknown>;
      const parts: string[] = [];
      if (parsed.seedId) parts.push(String(parsed.seedId));
      if (parsed.phase) parts.push(`phase:${parsed.phase}`);
      if (parsed.title && parsed.title !== parsed.seedId) parts.push(String(parsed.title));
      if (parsed.reason) parts.push(String(parsed.reason).slice(0, 60));
      if (parsed.branch) parts.push(`branch:${parsed.branch}`);
      if (parsed.commitHash) parts.push(String(parsed.commitHash).slice(0, 8));
      if (parts.length > 0) detail = ` — ${parts.join(" ")}`;
    } catch {
      detail = ` — ${event.details.slice(0, 60)}`;
    }
  }

  const typeColor = event.event_type === "fail" || event.event_type === "conflict" || event.event_type === "test-fail"
    ? chalk.red
    : event.event_type === "stuck"
    ? chalk.yellow
    : event.event_type === "complete" || event.event_type === "merge"
    ? chalk.green
    : chalk.dim;

  return `  ${typeColor(icon)} ${chalk.dim(event.event_type)}${chalk.dim(detail)} ${chalk.dim(`(${age} ago)`)}`;
}

/**
 * Render a summary line for a project header.
 */
export function renderProjectHeader(project: Project, activeCount: number, metrics: Metrics): string {
  const lines: string[] = [];

  const costStr = metrics.totalCost > 0
    ? chalk.yellow(`$${metrics.totalCost.toFixed(2)} spent`)
    : chalk.dim("$0.00 spent");

  const tokenStr = metrics.totalTokens > 0
    ? chalk.dim(`${(metrics.totalTokens / 1000).toFixed(1)}k tokens`)
    : "";

  const statusParts = [costStr];
  if (tokenStr) statusParts.push(tokenStr);

  lines.push(
    `${chalk.bold.cyan("PROJECT:")} ${chalk.bold(project.name)}  ${chalk.dim(project.path)}`,
  );
  lines.push(`  ${statusParts.join("  ")}  ${chalk.blue(`${activeCount} active agent${activeCount !== 1 ? "s" : ""}`)}`);

  return lines.join("\n");
}

/**
 * Render the "Needs Human" panel for tasks requiring operator attention.
 * Satisfies REQ-011.
 *
 * @param tasks   - Pre-sorted list of tasks needing human attention.
 * @param maxRows - Maximum rows to display (default: 10).
 */
export function renderNeedsHumanPanel(tasks: NativeTask[], maxRows = 10): string {
  if (tasks.length === 0) return "";

  const lines: string[] = [];
  lines.push(chalk.bold.red("⚠  NEEDS HUMAN ATTENTION:"));
  lines.push(THICK_RULE);

  const visible = tasks.slice(0, maxRows);
  for (const task of visible) {
    const statusLabel = taskStatusColor(task.status)(task.status.toUpperCase().padEnd(9));
    const priorityLabel = chalk.dim(`P${task.priority}`);
    const ageStr = chalk.dim(elapsed(task.updated_at) + " ago");
    const projectLabel = task.projectName
      ? chalk.dim(` [${task.projectName}]`)
      : "";
    const titleStr = task.title.slice(0, 55);
    lines.push(
      `  ${statusLabel} ${priorityLabel}  ${chalk.white(titleStr)}${projectLabel}  ${ageStr}`
    );
  }

  if (tasks.length > maxRows) {
    lines.push(chalk.dim(`  … and ${tasks.length - maxRows} more`));
  }

  lines.push("");
  return lines.join("\n");
}

/**
 * Render a per-project agent panel section.
 * Shows active agents with progress, then recently completed agents.
 * Satisfies REQ-012.
 */
export function renderProjectAgentPanel(
  project: Project,
  activeRuns: Run[],
  completedRuns: Run[],
  progresses: Map<string, RunProgress | null>,
  metrics: Metrics,
  events: Event[],
  offline: boolean,
): string {
  const lines: string[] = [];

  // Project header with offline indicator
  const offlineSuffix = offline ? chalk.red(" [offline]") : "";
  lines.push(renderProjectHeader(project, activeRuns.length, metrics) + offlineSuffix);
  lines.push(RULE);

  if (offline) {
    lines.push(chalk.dim("  (database inaccessible)"));
    lines.push("");
    return lines.join("\n");
  }

  // Active agents
  if (activeRuns.length > 0) {
    lines.push(chalk.bold("  ACTIVE AGENTS:"));
    for (const run of activeRuns) {
      const progress = progresses.get(run.id) ?? null;
      const card = renderAgentCard(run, progress)
        .split("\n")
        .map((l) => "    " + l)
        .join("\n");
      lines.push(card);
      lines.push("");
    }
  } else {
    lines.push(chalk.dim("  (no agents running)"));
    lines.push("");
  }

  // Recently completed agents (show up to 3)
  const recentCompleted = completedRuns.slice(0, 3);
  if (recentCompleted.length > 0) {
    lines.push(chalk.bold("  RECENTLY COMPLETED:"));
    for (const run of recentCompleted) {
      const progress = progresses.get(run.id) ?? null;
      const card = renderAgentCard(run, progress, false)
        .split("\n")
        .map((l) => "    " + l)
        .join("\n");
      lines.push(card);
    }
    lines.push("");
  }

  // Recent events
  if (events.length > 0) {
    lines.push(chalk.bold("  RECENT EVENTS:"));
    for (const event of events) {
      lines.push(renderEventLine(event));
    }
    lines.push("");
  }

  lines.push("");
  return lines.join("\n");
}

/**
 * Render the full dashboard display as a string.
 */
export function renderDashboard(state: DashboardState): string {
  const lines: string[] = [];

  // Header
  lines.push(
    `${chalk.bold("Foreman Dashboard")} ${chalk.dim("— Agent Observability")}  ${chalk.dim("(Ctrl+C to detach)")}`,
  );
  lines.push(THICK_RULE);
  lines.push("");

  if (state.projects.length === 0) {
    lines.push(chalk.dim("  No projects registered. Run 'foreman init' to get started."));
    lines.push("");
    lines.push(THICK_RULE);
    lines.push(chalk.dim(`Last updated: ${state.lastUpdated.toLocaleTimeString()}`));
    return lines.join("\n");
  }

  // "Needs Human" panel — shown at top if any tasks need attention (REQ-011)
  const needsHuman = state.needsHumanTasks ?? [];
  if (needsHuman.length > 0) {
    lines.push(renderNeedsHumanPanel(needsHuman));
  }

  // Per-project agent panels (REQ-012)
  for (const project of state.projects) {
    const activeRuns = state.activeRuns.get(project.id) ?? [];
    const completedRuns = state.completedRuns.get(project.id) ?? [];
    const projectMetrics = state.metrics.get(project.id) ?? {
      totalCost: 0, totalTokens: 0, tasksByStatus: {}, costByRuntime: [],
    };
    const events = state.events.get(project.id) ?? [];
    const offline = state.offlineProjects?.has(project.id) ?? false;

    lines.push(renderProjectAgentPanel(
      project,
      activeRuns,
      completedRuns,
      state.progresses,
      projectMetrics,
      events,
      offline,
    ));
  }

  // Footer with global totals
  lines.push(THICK_RULE);
  let totalCost = 0;
  let totalTokens = 0;
  let totalActive = 0;
  for (const [, m] of state.metrics) {
    totalCost += m.totalCost;
    totalTokens += m.totalTokens;
  }
  for (const [, runs] of state.activeRuns) {
    totalActive += runs.length;
  }

  // Aggregate success rate across all projects using raw merged/failed counts
  let globalMerged = 0;
  let globalFailed = 0;
  for (const sr of (state.successRates ?? new Map()).values()) {
    globalMerged += sr.merged;
    globalFailed += sr.failed;
  }
  const globalTotal = globalMerged + globalFailed;
  const globalRate: number | null = globalTotal >= 3 ? globalMerged / globalTotal : null;

  lines.push(
    `${chalk.bold("TOTALS")}  ` +
    `${chalk.blue(`${totalActive} active`)}  ` +
    `${chalk.yellow(`$${totalCost.toFixed(2)}`)}  ` +
    `${chalk.dim(`${(totalTokens / 1000).toFixed(1)}k tokens`)}  ` +
    `${chalk.dim("success (24h)")} ${formatSuccessRate(globalRate)}`,
  );
  lines.push(chalk.dim(`Last updated: ${state.lastUpdated.toLocaleTimeString()}`));

  return lines.join("\n");
}

// ── Data polling ─────────────────────────────────────────────────────────

/**
 * Collect dashboard data from the store.
 * Used for single-project (legacy / --simple) mode.
 */
export function pollDashboard(store: ForemanStore, projectId?: string, eventsLimit = 8): DashboardState {
  const projects = projectId
    ? [store.getProject(projectId)].filter((p): p is Project => p !== null)
    : store.listProjects();

  const activeRuns = new Map<string, Run[]>();
  const completedRuns = new Map<string, Run[]>();
  const progresses = new Map<string, RunProgress | null>();
  const metrics = new Map<string, Metrics>();
  const events = new Map<string, Event[]>();
  const successRates = new Map<string, { rate: number | null; merged: number; failed: number }>();

  for (const project of projects) {
    const active = store.getActiveRuns(project.id);
    activeRuns.set(project.id, active);

    // Recently completed (last 5)
    const completed = store.getRunsByStatus("completed", project.id).slice(0, 5);
    completedRuns.set(project.id, completed);

    // Get progress for all relevant runs
    for (const run of [...active, ...completed]) {
      if (!progresses.has(run.id)) {
        progresses.set(run.id, store.getRunProgress(run.id));
      }
    }

    metrics.set(project.id, store.getMetrics(project.id));
    events.set(project.id, store.getEvents(project.id, eventsLimit));
    successRates.set(project.id, store.getSuccessRate(project.id));
  }

  // Collect "needs human" tasks from the current store's project DBs
  const needsHumanTasks: NativeTask[] = [];
  for (const project of projects) {
    try {
      const tasks = store.listTasksByStatus([...NEEDS_HUMAN_STATUSES]);
      for (const t of tasks) {
        needsHumanTasks.push({ ...t, projectId: project.id, projectName: project.name });
      }
    } catch { /* tasks table may not exist */ }
  }

  return {
    projects,
    activeRuns,
    completedRuns,
    progresses,
    metrics,
    events,
    lastUpdated: new Date(),
    successRates,
    needsHumanTasks: sortNeedsHumanTasks(needsHumanTasks),
  };
}

// ── Simple (compact) dashboard renderer ─────────────────────────────────

/**
 * Render a simplified single-project dashboard view.
 * Used by `dashboard --simple` for a compact status display similar to
 * `foreman status --watch` but using the dashboard's data layer.
 *
 * Shows: task counts (from br), active agents, costs — no event timeline,
 * no recently-completed section, no multi-project header.
 */
export function renderSimpleDashboard(
  state: DashboardState,
  counts: DashboardTaskCounts,
  projectId?: string,
): string {
  const lines: string[] = [];

  // Pick the target project (first, or the filtered one)
  const project = projectId
    ? state.projects.find((p) => p.id === projectId)
    : state.projects[0];

  lines.push(
    `${chalk.bold("Foreman Status")} ${chalk.dim("— compact view")}  ${chalk.dim("(Ctrl+C to stop)")}`,
  );
  lines.push(THICK_RULE);
  lines.push("");

  // Task counts section
  lines.push(chalk.bold("Tasks"));
  lines.push(`  Total:       ${chalk.white(counts.total)}`);
  lines.push(`  Ready:       ${chalk.green(counts.ready)}`);
  lines.push(`  In Progress: ${chalk.yellow(counts.inProgress)}`);
  lines.push(`  Completed:   ${chalk.cyan(counts.completed)}`);
  if (counts.blocked > 0) {
    lines.push(`  Blocked:     ${chalk.red(counts.blocked)}`);
  }

  // Success rate: look up from the first project in state
  {
    const proj = projectId
      ? state.projects.find((p) => p.id === projectId)
      : state.projects[0];
    if (proj) {
      const sr = state.successRates?.get(proj.id);
      if (sr !== undefined) {
        const rateStr = formatSuccessRate(sr.rate);
        const hint = sr.rate === null ? chalk.dim(" (need 3+ runs)") : "";
        lines.push(`  Success Rate (24h): ${rateStr}${hint}`);
      }
    }
  }
  lines.push("");

  if (!project) {
    lines.push(chalk.dim("  No projects registered. Run 'foreman init' to get started."));
    lines.push("");
    lines.push(THICK_RULE);
    lines.push(chalk.dim(`Last updated: ${state.lastUpdated.toLocaleTimeString()}`));
    return lines.join("\n");
  }

  const activeRuns = state.activeRuns.get(project.id) ?? [];
  const projectMetrics = state.metrics.get(project.id) ?? {
    totalCost: 0, totalTokens: 0, tasksByStatus: {}, costByRuntime: [],
  };

  // Active agents
  lines.push(chalk.bold("Active Agents"));
  if (activeRuns.length === 0) {
    lines.push(chalk.dim("  (no agents running)"));
  } else {
    for (const run of activeRuns) {
      const progress = state.progresses.get(run.id) ?? null;
      const card = renderAgentCard(run, progress)
        .split("\n")
        .map((l) => "  " + l)
        .join("\n");
      lines.push(card);
    }
  }
  lines.push("");

  // Cost summary (only if non-zero)
  if (projectMetrics.totalCost > 0) {
    lines.push(chalk.bold("Costs"));
    lines.push(`  Total: ${chalk.yellow(`$${projectMetrics.totalCost.toFixed(2)}`)}`);
    lines.push(`  Tokens: ${chalk.dim(`${(projectMetrics.totalTokens / 1000).toFixed(1)}k`)}`);
    lines.push("");
  }

  lines.push(THICK_RULE);
  lines.push(chalk.dim(`Last updated: ${state.lastUpdated.toLocaleTimeString()}`));
  lines.push(chalk.dim(`Tip: use 'foreman status --live' for a full unified dashboard`));

  return lines.join("\n");
}

// ── Interactive actions ──────────────────────────────────────────────────

/**
 * Approve a backlog task via a short-lived write connection.
 * Satisfies REQ-011.3 backend requirement.
 *
 * Opens a new read-write ForemanStore for the task's project, updates the
 * task status to 'ready', then immediately closes the connection.
 *
 * @param taskId     - Native task UUID.
 * @param projectPath - Path to the project that owns this task.
 */
export function approveTask(taskId: string, projectPath: string): void {
  const store = ForemanStore.forProject(projectPath);
  try {
    store.updateTaskStatus(taskId, "ready");
  } finally {
    store.close();
  }
}

/**
 * Retry a failed/stuck/conflict task via a short-lived write connection.
 * Resets the task status to 'backlog' so it can be re-dispatched.
 * Satisfies REQ-011.3 backend requirement.
 *
 * @param taskId     - Native task UUID.
 * @param projectPath - Path to the project that owns this task.
 */
export function retryTask(taskId: string, projectPath: string): void {
  const store = ForemanStore.forProject(projectPath);
  try {
    store.updateTaskStatus(taskId, "backlog");
  } finally {
    store.close();
  }
}

// ── Command ───────────────────────────────────────────────────────────────

export const dashboardCommand = new Command("dashboard")
  .description("Live agent observability dashboard with real-time TUI")
  .option("--interval <ms>", "Polling interval in milliseconds (deprecated, use --refresh)", "")
  .option("--refresh <ms>", "Refresh interval in milliseconds (default: 5000; min: 1000)", "")
  .option("--project <id>", "Filter to specific project ID")
  .option("--no-watch", "Single snapshot, no polling")
  .option("--events <n>", "Number of recent events to show per project", "8")
  .option("--simple", "Compact single-project view with task counts (like 'foreman status --watch')")
  .action(async (opts: {
    interval: string;
    refresh: string;
    project?: string;
    watch: boolean;
    events: string;
    simple?: boolean;
  }) => {
    const projectPath = process.cwd();
    const store = ForemanStore.forProject(projectPath);

    // Refresh interval: CLI --refresh > CLI --interval > config.yaml > default 5000ms
    const configRefresh = loadDashboardConfig(projectPath).refreshInterval;
    const rawRefresh = opts.refresh || opts.interval;
    const intervalMs = rawRefresh
      ? Math.max(1000, parseInt(rawRefresh, 10) || configRefresh)
      : configRefresh;

    const projectId = opts.project;
    const watch = opts.watch !== false;
    const eventsLimit = Math.max(1, parseInt(opts.events, 10) || 8);
    const simple = opts.simple === true;

    // ── Simple (compact) mode ─────────────────────────────────────────────
    if (simple) {
      // Single-shot simple mode
      if (!watch) {
        try {
          const state = pollDashboard(store, projectId, eventsLimit);
          let counts: DashboardTaskCounts = { total: 0, ready: 0, inProgress: 0, completed: 0, blocked: 0 };
          try { counts = await fetchDashboardTaskCounts(projectPath); } catch { /* ignore */ }
          console.log(renderSimpleDashboard(state, counts, projectId));
        } finally {
          store.close();
        }
        return;
      }

      // Live simple mode
      let detachedSimple = false;
      const onSigintSimple = () => {
        if (detachedSimple) return;
        detachedSimple = true;
        process.stdout.write("\x1b[?25h\n");
        console.log(chalk.dim("  Detached — agents continue in background."));
        console.log(chalk.dim("  Tip: 'foreman status --live' for a full unified dashboard."));
        store.close();
        process.exit(0);
      };
      process.on("SIGINT", onSigintSimple);
      process.stdout.write("\x1b[?25l");

      try {
        while (!detachedSimple) {
          const state = pollDashboard(store, projectId, eventsLimit);
          let counts: DashboardTaskCounts = { total: 0, ready: 0, inProgress: 0, completed: 0, blocked: 0 };
          try { counts = await fetchDashboardTaskCounts(projectPath); } catch { /* ignore */ }
          const display = renderSimpleDashboard(state, counts, projectId);
          process.stdout.write("\x1B[2J\x1B[H" + display + "\n");
          await new Promise<void>((r) => setTimeout(r, intervalMs));
        }
      } finally {
        process.stdout.write("\x1b[?25h");
        process.removeListener("SIGINT", onSigintSimple);
        store.close();
      }
      return;
    }

    // ── Multi-project full dashboard mode ─────────────────────────────────
    // Use readProjectSnapshot() for concurrent READONLY reads (REQ-010, REQ-019)
    const registeredProjects = readProjectRegistry(store);
    const projectsToShow = projectId
      ? registeredProjects.filter((p) => p.id === projectId)
      : registeredProjects;

    // ── Single-shot full mode ─────────────────────────────────────────────
    if (!watch) {
      try {
        const snapshots = await readProjectSnapshot(projectsToShow, eventsLimit);
        const state = aggregateSnapshots(snapshots);
        console.log(renderDashboard(state));
      } finally {
        store.close();
      }
      return;
    }

    // ── Live full dashboard mode ──────────────────────────────────────────
    let detached = false;

    const onSigint = () => {
      if (detached) return;
      detached = true;
      process.stdout.write("\x1b[?25h\n"); // restore cursor
      console.log(chalk.dim("  Detached — agents continue in background."));
      console.log(chalk.dim("  Check status: foreman status"));
      console.log(chalk.dim("  Monitor runs: foreman monitor\n"));
      store.close();
      process.exit(0);
    };

    process.on("SIGINT", onSigint);
    process.stdout.write("\x1b[?25l"); // hide cursor

    try {
      while (!detached) {
        // Re-read project list each iteration in case new projects registered
        const currentProjects = readProjectRegistry(store);
        const filtered = projectId
          ? currentProjects.filter((p) => p.id === projectId)
          : currentProjects;

        const snapshots = await readProjectSnapshot(filtered, eventsLimit);
        const state = aggregateSnapshots(snapshots);
        const display = renderDashboard(state);
        process.stdout.write("\x1B[2J\x1B[H" + display + "\n");
        await new Promise<void>((r) => setTimeout(r, intervalMs));
      }
    } finally {
      process.stdout.write("\x1b[?25h"); // restore cursor on any exit
      process.removeListener("SIGINT", onSigint);
      store.close();
    }
  });
