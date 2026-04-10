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
} from "../../lib/store.js";
import { formatPriorityLabel, normalizePriority } from "../../lib/priority.js";
import { elapsed, renderAgentCard, formatSuccessRate } from "../watch-ui.js";
import { BeadsRustClient } from "../../lib/beads-rust.js";
import type { BrIssue } from "../../lib/beads-rust.js";
import type { Issue } from "../../lib/task-client.js";
import { loadDashboardConfig } from "../../lib/project-config.js";
import { ProjectRegistry } from "../../lib/project-registry.js";

// ── Task count helpers (for --simple mode) ───────────────────────────────

/**
 * Task counts fetched from the br backend for display in dashboard --simple.
 */
export interface DashboardTaskCounts {
  total: number;
  ready: number;
  backlog: number;
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

  let backlogIssues: BrIssue[] = [];
  try { backlogIssues = await brClient.listBacklog(); } catch { /* backlog label query may fail */ }

  const inProgress = openIssues.filter((i) => i.status === "in_progress").length;
  const completed = closedIssues.length;
  const readyIds = new Set(readyIssues.map((i) => i.id));
  const backlogIds = new Set(backlogIssues.map((i) => i.id));
  const ready = readyIssues.length;
  const backlog = backlogIssues.length;
  const blocked = openIssues.filter(
    (i) => i.status !== "in_progress" && !readyIds.has(i.id) && !backlogIds.has(i.id),
  ).length;
  const total = openIssues.length + completed;

  return { total, ready, backlog, inProgress, completed, blocked };
}

// ── Types ─────────────────────────────────────────────────────────────────

/** Backlog bead surfaced in the full dashboard for operator approval. */
export interface DashboardBacklogBead {
  id: string;
  title: string;
  priority: string;
  status: string;
  created_at: string;
  updated_at: string;
  projectId: string;
  projectName: string;
  projectPath: string;
}

/** Snapshot of a single project collected via READONLY DB connection. */
export interface ProjectSnapshot {
  project: Project;
  activeRuns: Run[];
  completedRuns: Run[];
  progresses: Map<string, RunProgress | null>;
  metrics: Metrics;
  events: Event[];
  successRate: { rate: number | null; merged: number; failed: number };
  taskCounts: DashboardTaskCounts;
  backlogBeads: DashboardBacklogBead[];
  backlogLoadError: string | null;
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
  taskCounts?: Map<string, DashboardTaskCounts>;
  lastUpdated: Date;
  /** 24-hour success rate stats per project ID. rate=null means insufficient data. Optional for backward compat. */
  successRates?: Map<string, { rate: number | null; merged: number; failed: number }>;
  /** Cross-project backlog beads awaiting operator approval. */
  backlogBeads?: DashboardBacklogBead[];
  /** Per-project backlog fetch failures surfaced without aborting the dashboard loop. */
  backlogLoadErrors?: Map<string, string>;
  /** Whether each project is reachable (true = offline / DB inaccessible). */
  offlineProjects?: Set<string>;
}

function parseBacklogPriority(priority: string | number): number {
  return normalizePriority(priority);
}

export function sortBacklogBeads(beads: DashboardBacklogBead[]): DashboardBacklogBead[] {
  return [...beads].sort((a, b) => {
    const priorityDelta = parseBacklogPriority(a.priority) - parseBacklogPriority(b.priority);
    if (priorityDelta !== 0) return priorityDelta;

    const ageDelta = new Date(a.updated_at).getTime() - new Date(b.updated_at).getTime();
    if (ageDelta !== 0) return ageDelta;

    return a.projectName.localeCompare(b.projectName) || a.id.localeCompare(b.id);
  });
}

// ── Project Registry ─────────────────────────────────────────────────────

/**
 * A registered project entry used by multi-project dashboard aggregation.
 *
 * `id` is a rendering/runtime key. It prefers the project-local SQLite project row
 * when present so existing dashboard state maps continue to work. When a local
 * project row does not yet exist, the registry path is used as a stable fallback.
 * Registry name/path remain the operator-facing project authority.
 */
export interface RegisteredProject {
  id: string;
  name: string;
  path: string;
}

/**
 * Read the list of all registered projects from the global project registry.
 *
 * The registry is the authority for project enumeration. The local store is used
 * only to look up execution-local compatibility metadata (the current project row ID)
 * when it already exists in a project's SQLite database.
 *
 * @param store - ForemanStore for the current project (used only for local project lookup).
 * @param registry - Optional registry override for tests.
 * @returns Array of projects to include in the multi-project dashboard.
 */
export function readProjectRegistry(
  store: Pick<ForemanStore, "getProjectByPath">,
  registry: Pick<ProjectRegistry, "list"> = new ProjectRegistry(),
): RegisteredProject[] {
  return registry.list().map((project) => {
    const localProject = store.getProjectByPath(project.path);
    return {
      id: localProject?.id ?? project.path,
      name: project.name,
      path: project.path,
    };
  });
}

export function matchesRegisteredProject(project: RegisteredProject, selector: string): boolean {
  return project.id === selector || project.name === selector || project.path === selector;
}

async function fetchDashboardBacklogBeads(project: RegisteredProject): Promise<DashboardBacklogBead[]> {
  const brClient = new BeadsRustClient(project.path);
  const backlogIssues = await brClient.listBacklog();

  return sortBacklogBeads(backlogIssues.map((issue) => ({
    id: issue.id,
    title: issue.title,
    priority: formatPriorityLabel(issue.priority),
    status: issue.status,
    created_at: issue.created_at,
    updated_at: issue.updated_at,
    projectId: project.id,
    projectName: project.name,
    projectPath: project.path,
  })));
}
// ── READONLY snapshot helpers ─────────────────────────────────────────────

/**
 * Read a single project's snapshot from its database using a READONLY connection.
 * Returns an "offline" snapshot if the DB is inaccessible.
 *
 * @param project    - Project metadata (id, name, path).
 * @param eventsLimit - Max events to fetch.
 */
async function readProjectDbSnapshot(
  project: RegisteredProject,
  eventsLimit: number,
): Promise<ProjectSnapshot> {
  const dbPath = join(project.path, ".foreman", "foreman.db");

  // Return offline indicator if DB file doesn't exist
  if (!existsSync(dbPath)) {
    return makeOfflineSnapshot(project);
  }

  let db: Database.Database | null = null;
  try {
    db = ForemanStore.openReadonly(project.path);
    const taskCounts = await fetchDashboardTaskCounts(project.path);
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

    let backlogBeads: DashboardBacklogBead[] = [];
    let backlogLoadError: string | null = null;
    try {
      backlogBeads = await fetchDashboardBacklogBeads(project);
    } catch (error) {
      backlogLoadError = error instanceof Error ? error.message : String(error);
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
      taskCounts,
      backlogBeads,
      backlogLoadError,
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
    taskCounts: { total: 0, ready: 0, backlog: 0, inProgress: 0, completed: 0, blocked: 0 },
    backlogBeads: [],
    backlogLoadError: null,
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
  const taskCounts = new Map<string, DashboardTaskCounts>();
  const successRates = new Map<string, { rate: number | null; merged: number; failed: number }>();
  const backlogLoadErrors = new Map<string, string>();
  const backlogBeads: DashboardBacklogBead[] = [];
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
    taskCounts.set(snap.project.id, snap.taskCounts);
    successRates.set(snap.project.id, snap.successRate);
    backlogBeads.push(...snap.backlogBeads);
    if (snap.backlogLoadError) {
      backlogLoadErrors.set(snap.project.id, snap.backlogLoadError);
    }
  }

  return {
    projects,
    activeRuns,
    completedRuns,
    progresses,
    metrics,
    events,
    taskCounts,
    lastUpdated: new Date(),
    successRates,
    backlogBeads: sortBacklogBeads(backlogBeads),
    backlogLoadErrors,
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

// ── Backlog display helpers ────────────────────────────────────────────────

type ChalkColor = (text: string) => string;
function backlogPriorityColor(priority: string): ChalkColor {
  switch (parseBacklogPriority(priority)) {
    case 0: return chalk.bgRed.white;
    case 1: return chalk.red;
    case 2: return chalk.yellow;
    default: return chalk.dim;
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
 * Render the backlog approval panel for beads waiting on operator release.
 */
export function renderBacklogPanel(
  beads: DashboardBacklogBead[],
  options?: {
    maxRows?: number;
    selectedIndex?: number;
    notice?: string | null;
    backlogLoadErrors?: Map<string, string>;
  },
): string {
  const maxRows = options?.maxRows ?? 10;
  const selectedIndex = options?.selectedIndex ?? -1;
  const backlogLoadErrors = [...(options?.backlogLoadErrors ?? new Map()).entries()];
  const lines: string[] = [];

  lines.push(chalk.bold.yellow("⏸  APPROVAL BACKLOG:"));
  lines.push(THICK_RULE);

  if (beads.length === 0) {
    lines.push(chalk.dim("  No backlog beads await approval."));
  } else {
    const start = selectedIndex >= maxRows
      ? Math.min(selectedIndex - maxRows + 1, Math.max(0, beads.length - maxRows))
      : 0;
    const visible = beads.slice(start, start + maxRows);

    for (const [index, bead] of visible.entries()) {
      const absoluteIndex = start + index;
      const marker = absoluteIndex === selectedIndex ? chalk.cyan("›") : " ";
      const priorityLabel = backlogPriorityColor(bead.priority)(bead.priority.padEnd(3));
      const projectLabel = chalk.dim(`[${bead.projectName}]`);
      const ageLabel = chalk.dim(`${elapsed(bead.updated_at)} ago`);
      const title = bead.title.slice(0, 52);
      lines.push(` ${marker} ${priorityLabel}  ${chalk.white(title)} ${chalk.dim(`(${bead.id})`)} ${projectLabel}  ${ageLabel}`);
    }

    if (beads.length > maxRows) {
      lines.push(chalk.dim(`  … showing ${start + 1}-${start + visible.length} of ${beads.length}`));
    }

    lines.push(chalk.dim("  j/k move  a approve selected backlog bead"));
  }

  if (backlogLoadErrors.length > 0) {
    lines.push(chalk.yellow("  Backlog unavailable for:"));
    for (const [projectId, error] of backlogLoadErrors) {
      lines.push(chalk.dim(`    ${projectId}: ${error}`));
    }
  }

  if (options?.notice) {
    lines.push(`  ${options.notice}`);
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
  taskCounts?: DashboardTaskCounts,
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
  if (taskCounts) {
    const queueSummary = [
      `ready ${chalk.green(taskCounts.ready)}`,
      `backlog ${chalk.dim(taskCounts.backlog)}`,
      `in-progress ${chalk.yellow(taskCounts.inProgress)}`,
      `blocked ${chalk.red(taskCounts.blocked)}`,
      `completed ${chalk.cyan(taskCounts.completed)}`,
    ].join("  ");
    lines.push(chalk.bold("  TASK QUEUE:"));
    lines.push(`    ${queueSummary}`);
    lines.push("");
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
export function renderDashboard(
  state: DashboardState,
  options?: { selectedBacklogIndex?: number; backlogNotice?: string | null },
): string {
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

  const backlogBeads = state.backlogBeads ?? [];
  const backlogLoadErrors = state.backlogLoadErrors ?? new Map<string, string>();
  if (backlogBeads.length > 0 || backlogLoadErrors.size > 0) {
    lines.push(renderBacklogPanel(backlogBeads, {
      selectedIndex: options?.selectedBacklogIndex,
      notice: options?.backlogNotice ?? null,
      backlogLoadErrors,
    }));
  }

  // Per-project agent panels (REQ-012)
  for (const project of state.projects) {
    const activeRuns = state.activeRuns.get(project.id) ?? [];
    const completedRuns = state.completedRuns.get(project.id) ?? [];
    const projectMetrics = state.metrics.get(project.id) ?? {
      totalCost: 0, totalTokens: 0, tasksByStatus: {}, costByRuntime: [],
    };
    const events = state.events.get(project.id) ?? [];
    const taskCounts = state.taskCounts?.get(project.id);
    const offline = state.offlineProjects?.has(project.id) ?? false;

    lines.push(renderProjectAgentPanel(
      project,
      activeRuns,
      completedRuns,
      state.progresses,
      projectMetrics,
      events,
      offline,
      taskCounts,
    ));
  }

  // Footer with global totals
  lines.push(THICK_RULE);
  let totalCost = 0;
  let totalTokens = 0;
  let totalActive = 0;
  let totalReady = 0;
  let totalBacklog = 0;
  let totalBlocked = 0;
  for (const [, m] of state.metrics) {
    totalCost += m.totalCost;
    totalTokens += m.totalTokens;
  }
  for (const [, runs] of state.activeRuns) {
    totalActive += runs.length;
  }
  for (const [, counts] of state.taskCounts ?? new Map<string, DashboardTaskCounts>()) {
    totalReady += counts.ready;
    totalBacklog += counts.backlog;
    totalBlocked += counts.blocked;
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
    `${chalk.green(`ready ${totalReady}`)}  ` +
    `${chalk.dim(`backlog ${totalBacklog}`)}  ` +
    `${chalk.red(`blocked ${totalBlocked}`)}  ` +
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

  const taskCounts = new Map<string, DashboardTaskCounts>();
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
    taskCounts.set(project.id, { total: 0, ready: 0, backlog: 0, inProgress: 0, completed: 0, blocked: 0 });
  }

  // Public dashboard output is beads-first; the compact status view does not fetch
  // backlog bead details, so keep that panel empty here.
  const backlogBeads: DashboardBacklogBead[] = [];

  return {
    projects,
    activeRuns,
    completedRuns,
    progresses,
    metrics,
    events,
    taskCounts,
    lastUpdated: new Date(),
    successRates,
    backlogBeads: sortBacklogBeads(backlogBeads),
    backlogLoadErrors: new Map(),
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
  if (counts.backlog > 0) {
    lines.push(`  Backlog:     ${chalk.dim(counts.backlog)}`);
  }
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
 * Approve a backlog bead via the beads-first backend.
 *
 * @param beadId      - Bead ID awaiting approval.
 * @param projectPath - Path to the project that owns this bead.
 */
export async function approveBacklogBead(
  beadId: string,
  projectPath: string,
  opts?: { recursive?: boolean },
): Promise<{ approved: string[]; skipped: string[] }> {
  const client = new BeadsRustClient(projectPath);
  return client.approve(beadId, { recursive: opts?.recursive !== false });
}

// ── Command ───────────────────────────────────────────────────────────────

export const dashboardCommand = new Command("dashboard")
  .description("Live control-plane dashboard across registered projects")
  .option("--interval <ms>", "Polling interval in milliseconds (deprecated, use --refresh)", "")
  .option("--refresh <ms>", "Refresh interval in milliseconds (default: 5000; min: 1000)", "")
  .option("--project <name-or-path>", "Scope the dashboard to one registered project by name or path (legacy local project IDs still resolve for compatibility)")
  .option("--no-watch", "Single snapshot, no polling")
  .option("--events <n>", "Number of recent events to show per project", "8")
  .option("--simple", "Compact single-project execution view with task counts")
  .action(async (opts: {
    interval: string;
    refresh: string;
    project?: string;
    watch: boolean;
    events: string;
    simple?: boolean;
  }) => {
    const cwdProjectPath = process.cwd();
    const registry = new ProjectRegistry();
    const registryMatch = opts.project
      ? registry.list().find((project) => project.name === opts.project || project.path === opts.project)
      : undefined;
    const projectPath = registryMatch?.path ?? cwdProjectPath;
    const store = ForemanStore.forProject(projectPath);

    // Refresh interval: CLI --refresh > CLI --interval > config.yaml > default 5000ms
    const configRefresh = loadDashboardConfig(projectPath).refreshInterval;
    const rawRefresh = opts.refresh || opts.interval;
    const intervalMs = rawRefresh
      ? Math.max(1000, parseInt(rawRefresh, 10) || configRefresh)
      : configRefresh;

    const projectSelector = opts.project;
    const watch = opts.watch !== false;
    const eventsLimit = Math.max(1, parseInt(opts.events, 10) || 8);
    const simple = opts.simple === true;
    const registeredProjects = readProjectRegistry(store, registry);
    const projectsToShow = projectSelector
      ? registeredProjects.filter((project) => matchesRegisteredProject(project, projectSelector))
      : registeredProjects;
    const selectedProjectId = projectsToShow[0]?.id ?? projectSelector;

    // ── Simple (compact) mode ─────────────────────────────────────────────
    if (simple) {
      // Single-shot simple mode
      if (!watch) {
        try {
          const state = pollDashboard(store, selectedProjectId, eventsLimit);
          let counts: DashboardTaskCounts = { total: 0, ready: 0, backlog: 0, inProgress: 0, completed: 0, blocked: 0 };
          try { counts = await fetchDashboardTaskCounts(projectPath); } catch { /* ignore */ }
          console.log(renderSimpleDashboard(state, counts, selectedProjectId));
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
          const state = pollDashboard(store, selectedProjectId, eventsLimit);
          let counts: DashboardTaskCounts = { total: 0, ready: 0, backlog: 0, inProgress: 0, completed: 0, blocked: 0 };
          try { counts = await fetchDashboardTaskCounts(projectPath); } catch { /* ignore */ }
          const display = renderSimpleDashboard(state, counts, selectedProjectId);
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

    let backlogBeads: DashboardBacklogBead[] = [];
    let selectedBacklogIndex = -1;
    let backlogNotice: string | null = null;
    let stdinRawMode = false;
    let sleepResolve: (() => void) | null = null;

    const wakeAndRender = () => {
      if (sleepResolve) {
        sleepResolve();
        sleepResolve = null;
      }
    };

    const handleBacklogKey = async (chunk: string | Buffer) => {
      const key = chunk.toString();
      const beads = backlogBeads;

      if (key === "\u001B[A" || key === "k") {
        if (beads.length > 0) {
          selectedBacklogIndex = selectedBacklogIndex <= 0 ? beads.length - 1 : selectedBacklogIndex - 1;
          wakeAndRender();
        }
      } else if (key === "\u001B[B" || key === "j") {
        if (beads.length > 0) {
          selectedBacklogIndex = selectedBacklogIndex >= beads.length - 1 ? 0 : selectedBacklogIndex + 1;
          wakeAndRender();
        }
      } else if (key === "a" || key === "A") {
        if (selectedBacklogIndex >= 0 && selectedBacklogIndex < beads.length) {
          const bead = beads[selectedBacklogIndex];
          backlogNotice = chalk.dim(`Approving ${bead.id}…`);
          wakeAndRender();
          try {
            const result = await approveBacklogBead(bead.id, bead.projectPath);
            backlogNotice = result.approved.length > 0
              ? chalk.green(`Approved ${result.approved.join(", ")} for dispatch`)
              : chalk.yellow(`${bead.id} was already approved.`);
          } catch (error) {
            backlogNotice = chalk.red(
              `Approval failed for ${bead.id}: ${error instanceof Error ? error.message : String(error)}`,
            );
          }
          selectedBacklogIndex = -1;
          wakeAndRender();
        }
      } else if (key === "\r" || key === "\n") {
        selectedBacklogIndex = -1;
        wakeAndRender();
      } else if (key.length === 1 && selectedBacklogIndex !== -1) {
        selectedBacklogIndex = -1;
        wakeAndRender();
      }
    };

    if (process.stdin.isTTY && typeof process.stdin.setRawMode === "function") {
      try {
        process.stdin.setRawMode(true);
        process.stdin.resume();
        process.stdin.setEncoding("utf8");
        process.stdin.on("data", handleBacklogKey);
        stdinRawMode = true;
      } catch {
        // Continue without keyboard handling when raw mode is unavailable.
      }
    }

    try {
      while (!detached) {
        // Re-read project list each iteration in case new projects registered
        const currentProjects = readProjectRegistry(store, registry);
        const filtered = projectSelector
          ? currentProjects.filter((project) => matchesRegisteredProject(project, projectSelector))
          : currentProjects;

        const snapshots = await readProjectSnapshot(filtered, eventsLimit);
        const state = aggregateSnapshots(snapshots);
        backlogBeads = state.backlogBeads ?? [];
        if (selectedBacklogIndex >= backlogBeads.length) {
          selectedBacklogIndex = backlogBeads.length > 0 ? backlogBeads.length - 1 : -1;
        }
        const display = renderDashboard(state, {
          selectedBacklogIndex,
          backlogNotice,
        });
        process.stdout.write("\x1B[2J\x1B[H" + display + "\n");
        await new Promise<void>((resolve) => {
          sleepResolve = resolve;
          setTimeout(resolve, intervalMs);
        });
        sleepResolve = null;
      }
    } finally {
      process.stdout.write("\x1b[?25h"); // restore cursor on any exit
      process.removeListener("SIGINT", onSigint);
      if (stdinRawMode) {
        process.stdin.off("data", handleBacklogKey);
        try {
          process.stdin.setRawMode(false);
        } catch {
          // ignore restore failures
        }
      }
      store.close();
    }
  });
