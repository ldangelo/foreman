/**
 * Dashboard data + rendering layer (shared library).
 *
 * Extracted from the retired `foreman dashboard` command. `foreman watch` is
 * now the canonical live TUI; this module provides the daemon-backed state
 * polling, READONLY multi-project snapshots, and the full-dashboard renderer
 * still used by:
 *   - `foreman status --live`            (status.ts)
 *   - `foreman watch` state + actions    (commands/watch/)
 */
import chalk from "chalk";
import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { join, resolve } from "node:path";
import { foremanBackendMode } from "../lib/backend-mode.js";
import { ElixirServerClient } from "../lib/elixir-server-client.js";
import { ElixirServerManager } from "../lib/elixir-server-manager.js";
import { createTrpcClient } from "../lib/trpc-client.js";
import {
  ForemanStore,
  type DashboardReadStore,
  type Project,
  type Run,
  type RunProgress,
  type Metrics,
  type Event,
  type NativeTask,
} from "../lib/store.js";
import { elapsed, renderAgentCard, formatSuccessRate } from "./watch-ui.js";
import { listRegisteredProjects } from "./commands/project-task-support.js";

// ── Daemon-backed state ───────────────────────────────────────────────────

interface DaemonDashboardStats {
  tasks: {
    backlog: number;
    ready: number;
    inProgress: number;
    approved: number;
    merged: number;
    closed: number;
    total: number;
  };
  runs: {
    active: number;
    pending: number;
  };
}

interface DaemonRunSummary {
  id: string;
  task_id: string;
  status: "pending" | "running";
  branch: string;
  started_at: string | null;
  queued_at: string;
  created_at: string;
}

interface DaemonProjectRecord {
  id: string;
  name: string;
  path: string;
}

async function createElixirDashboardClient(): Promise<ElixirServerClient> {
  const manager = new ElixirServerManager();
  const status = await manager.ensureRunning();
  return new ElixirServerClient(status.url, process.env.FOREMAN_SERVER_AUTH_TOKEN);
}

function deriveTaskMetrics(tasks: NativeTask[]): Metrics["tasksByStatus"] {
  const counts: Record<string, number> = {};
  for (const task of tasks) {
    counts[task.status] = (counts[task.status] ?? 0) + 1;
  }
  return counts;
}

async function resolveDashboardProjectRecord(
  projects: Array<{ id: string; name: string; path: string }>,
  projectPath: string,
  projectSelector?: string,
): Promise<{ id: string; name: string; path: string } | null> {
  if (projectSelector) {
    return projects.find((record) => record.id === projectSelector || record.name === projectSelector) ?? null;
  }
  const resolvedProjectPath = resolve(projectPath);
  return projects.find((record) => resolve(record.path) === resolvedProjectPath) ?? null;
}

export async function fetchDaemonDashboardState(projectPath: string, projectId?: string): Promise<DashboardState | null> {
  try {
    const projects = await listRegisteredProjects();
    const current = await resolveDashboardProjectRecord(projects, projectPath, projectId);
    const visible = current ? [current] : [];
    if (visible.length === 0) {
      if (foremanBackendMode() === "elixir") {
        throw new Error(`Project at '${projectPath}' is not registered in Elixir projections.`);
      }
      return null;
    }

    const projectRows: Project[] = [];
    const activeRuns = new Map<string, Run[]>();
    const completedRuns = new Map<string, Run[]>();
    const progresses = new Map<string, RunProgress | null>();
    const metrics = new Map<string, Metrics>();
    const events = new Map<string, Event[]>();
    const successRates = new Map<string, { rate: number | null; merged: number; failed: number }>();
    const needsHumanTasks: NativeTask[] = [];

    if (foremanBackendMode() === "elixir") {
      const client = await createElixirDashboardClient();
      const [allTasks, allRuns] = await Promise.all([client.listTasks(), client.listRuns()]);

      for (const project of visible as DaemonProjectRecord[]) {
        const projectTasks: NativeTask[] = allTasks
          .filter((task) => task.project_id === project.id)
          .map((task) => ({
            id: task.task_id ?? task.id ?? "unknown",
            title: task.title ?? (task.task_id ?? task.id ?? "unknown"),
            description: task.description ?? null,
            status: (task.status ?? "backlog") as NativeTask["status"],
            priority: typeof task.priority === "number" ? task.priority : 2,
            type: task.task_type ?? task.type ?? "task",
            external_id: task.external_id ?? null,
            created_at: task.created_at ?? task.updated_at ?? new Date().toISOString(),
            updated_at: task.updated_at ?? task.created_at ?? new Date().toISOString(),
            approved_at: task.approved_at ?? null,
            closed_at: task.closed_at ?? null,
            run_id: task.run_id ?? null,
            branch: null,
          }));
        const human = projectTasks.filter((task) => NEEDS_HUMAN_STATUSES.includes(task.status as NeedsHumanStatus));
        const runs = allRuns.filter((run) => run.project_id === project.id && ["pending", "running"].includes(String(run.status ?? "")));

        projectRows.push({
          id: project.id,
          name: project.name,
          path: project.path,
          status: "active",
          created_at: "",
          updated_at: "",
        });

        activeRuns.set(project.id, runs.map((run) => ({
          id: String(run.run_id ?? run.id ?? "unknown"),
          project_id: project.id,
          task_id: String(run.task_id ?? run.run_id ?? run.id ?? "unknown"),
          agent_type: "elixir",
          session_key: null,
          worktree_path: null,
          status: String(run.status ?? "running") as Run["status"],
          started_at: typeof run.started_at === "string" ? run.started_at : null,
          completed_at: null,
          created_at: typeof run.created_at === "string" ? run.created_at : new Date().toISOString(),
          progress: null,
          base_branch: null,
        })));
        completedRuns.set(project.id, []);
        events.set(project.id, []);
        successRates.set(project.id, { rate: null, merged: 0, failed: 0 });
        const withProject = human.map((task) => ({
          ...task,
          projectName: project.name,
          projectId: project.id,
          projectPath: project.path,
        }));
        needsHumanTasks.push(...withProject);
        metrics.set(project.id, {
          totalCost: 0,
          totalTokens: 0,
          tasksByStatus: deriveTaskMetrics(projectTasks),
          costByRuntime: [],
          totalTurns: undefined,
          costPerTurn: undefined,
          totalTimeSeconds: undefined,
          timePerTurnSeconds: undefined,
        });

        // Fetch metrics from Elixir API and update project metrics
        // Note: client.getMetrics() returns global totals across all projects
        try {
          const m = await client.getMetrics();
          const projectMetrics = metrics.get(project.id);
          if (projectMetrics && m) {
            const parseMetric = (value: unknown): number | undefined => {
              if (typeof value === 'number') return value;
              if (typeof value === 'string' && value !== '') {
                const parsed = parseFloat(value);
                return isNaN(parsed) ? undefined : parsed;
              }
              return undefined;
            };
            metrics.set(project.id, {
              ...projectMetrics,
              totalCost: typeof m.total_cost === 'number' ? m.total_cost : parseFloat(String(m.total_cost || '0')) || 0,
              totalTurns: m.total_turns,
              costPerTurn: parseMetric(m.cost_per_turn),
              totalTimeSeconds: m.total_time_seconds,
              timePerTurnSeconds: parseMetric(m.time_per_turn_seconds),
            });
          }
        } catch {
          // Fall back to empty metrics if API call fails
        }
      }

      return {
        projects: projectRows,
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

    const client = createTrpcClient();
    for (const project of visible as DaemonProjectRecord[]) {
      const [stats, human, runs] = await Promise.all([
        client.projects.stats({ projectId: project.id }) as Promise<DaemonDashboardStats>,
        client.projects.listNeedsHuman({ projectId: project.id }) as Promise<Array<NativeTask>>,
        client.runs.listActive({ projectId: project.id }) as Promise<DaemonRunSummary[]>,
      ]);

      projectRows.push({
        id: project.id,
        name: project.name,
        path: project.path,
        status: "active",
        created_at: "",
        updated_at: "",
      });

      activeRuns.set(project.id, runs.map((run) => ({
        id: run.id,
        project_id: project.id,
        task_id: run.task_id,
        agent_type: "daemon",
        session_key: null,
        worktree_path: null,
        status: run.status,
        started_at: run.started_at,
        completed_at: null,
        created_at: run.created_at,
        progress: null,
        base_branch: null,
      })));
      completedRuns.set(project.id, []);
      metrics.set(project.id, { totalCost: 0, totalTokens: 0, tasksByStatus: {}, costByRuntime: [] });
      events.set(project.id, []);
      successRates.set(project.id, { rate: null, merged: 0, failed: 0 });

      const withProject = human.map((task) => ({
        ...task,
        projectName: project.name,
        projectId: project.id,
        projectPath: project.path,
      }));
      needsHumanTasks.push(...withProject);
      metrics.set(project.id, {
        totalCost: 0,
        totalTokens: 0,
        tasksByStatus: {
          backlog: stats.tasks.backlog,
          ready: stats.tasks.ready,
          "in-progress": stats.tasks.inProgress,
          merged: stats.tasks.merged,
          closed: stats.tasks.closed,
        },
        costByRuntime: [],
      });
    }

    return {
      projects: projectRows,
      activeRuns,
      completedRuns,
      progresses,
      metrics,
      events,
      lastUpdated: new Date(),
      successRates,
      needsHumanTasks: sortNeedsHumanTasks(needsHumanTasks),
    };
  } catch (err) {
    if (foremanBackendMode() === "elixir") {
      throw err;
    }
    return null;
  }
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
 * @param store - DashboardReadStore for the current project (read-only interface).
 * @returns Array of projects to include in the multi-project dashboard.
 */
export function readProjectRegistry(store: DashboardReadStore): RegisteredProject[] {
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

  let db: ReturnType<typeof ForemanStore.openReadonly> | null = null;
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
      // Wrap in a Promise so synchronous fallback reads don't block the event loop
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
      if (parsed.taskId) parts.push(String(parsed.taskId));
      if (parsed.phase) parts.push(`phase:${parsed.phase}`);
      if (parsed.title && parsed.title !== parsed.taskId) parts.push(String(parsed.title));
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
  if (tasks.length === 0) {
    return (
      chalk.bold.red("⚠  NEEDS HUMAN ATTENTION:") + "\n" +
      THICK_RULE + "\n" +
      chalk.dim("  No tasks need attention.\n") +
      "\n"
    );
  }

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
 * Used for single-project (local fallback) mode.
 */
export function pollDashboard(store: DashboardReadStore, projectId?: string, eventsLimit = 8): DashboardState {
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

// ── Interactive actions ──────────────────────────────────────────────────

/**
 * Approve a backlog task via a short-lived write connection.
 * Satisfies REQ-011.3 backend requirement.
 *
 * Opens a new read-write ForemanStore for the task's project, updates the
 * task status to 'ready', then immediately closes the connection.
 *
 * @param taskId     - Native task ID.
 * @param projectPath - Path to the project that owns this task.
 */
export async function approveTask(taskId: string, projectPath: string): Promise<void> {
  const projects = await listRegisteredProjects();
  const resolvedProjectPath = resolve(projectPath);
  const project = projects.find((record) => resolve(record.path) === resolvedProjectPath);
  if (!project) throw new Error(`Project at '${projectPath}' is not registered with the daemon.`);

  if (foremanBackendMode() === "elixir") {
    const client = await createElixirDashboardClient();
    const response = await client.sendCommand({
      command_id: `watch-approve-${taskId}-${randomUUID()}`,
      command_type: "task.approve",
      payload: {
        project_id: project.id,
        task_id: taskId,
      },
    });
    if (!response.ok) throw new Error(response.error.message);
    return;
  }

  const client = createTrpcClient();
  await client.tasks.approve({ projectId: project.id, taskId });
}

/**
 * Retry a failed/stuck/conflict task via a short-lived write connection.
 * Resets the task status to 'backlog' so it can be re-dispatched.
 * Satisfies REQ-011.3 backend requirement.
 *
 * @param taskId     - Native task ID.
 * @param projectPath - Path to the project that owns this task.
 */
export async function retryTask(taskId: string, projectPath: string): Promise<void> {
  const projects = await listRegisteredProjects();
  const resolvedProjectPath = resolve(projectPath);
  const project = projects.find((record) => resolve(record.path) === resolvedProjectPath);
  if (!project) throw new Error(`Project at '${projectPath}' is not registered with the daemon.`);

  if (foremanBackendMode() === "elixir") {
    const client = await createElixirDashboardClient();
    const response = await client.sendCommand({
      command_id: `watch-retry-${taskId}-${randomUUID()}`,
      command_type: "task.update",
      payload: {
        project_id: project.id,
        task_id: taskId,
        status: "backlog",
      },
    });
    if (!response.ok) throw new Error(response.error.message);
    return;
  }

  const client = createTrpcClient();
  await client.tasks.retry({ projectId: project.id, taskId });
}
