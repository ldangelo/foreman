import { Command } from "commander";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { homedir } from "node:os";
import chalk from "chalk";
import { ForemanStore } from "../../lib/store.js";
import type { Metrics, Run, RunProgress } from "../../lib/store.js";
import { formatPriorityLabel, normalizePriority } from "../../lib/priority.js";
import { getSdkRunHealth, type SdkRunHealth } from "../../lib/run-health.js";
import { elapsed, renderAgentCard, formatSuccessRate } from "../watch-ui.js";
import { BeadsRustClient } from "../../lib/beads-rust.js";
import type { BrIssue } from "../../lib/beads-rust.js";
import type { TaskBackend } from "../../lib/feature-flags.js";
import type { Issue } from "../../lib/task-client.js";
import { resolveRepoRootProjectPath } from "./project-task-support.js";
import { ProjectRegistry } from "../../lib/project-registry.js";
import { pollDashboard, renderDashboard } from "./dashboard.js";

// ── Pi log activity helper ────────────────────────────────────────────────

/**
 * Read the last `tool_call` event from a Pi JSONL `.out` log file.
 * Returns a short description string, or null if none can be found.
 *
 * Reads the last 8 KB of the file to avoid loading large logs into memory.
 */
export async function getLastPiActivity(runId: string): Promise<string | null> {
  const logPath = join(homedir(), ".foreman", "logs", `${runId}.out`);
  try {
    const content = await readFile(logPath, "utf-8");
    // Walk lines in reverse to find the most recent tool_call
    const lines = content.split("\n");
    for (let i = lines.length - 1; i >= 0; i--) {
      const line = lines[i]?.trim();
      if (!line) continue;
      try {
        const obj = JSON.parse(line) as Record<string, unknown>;
        if (obj.type === "tool_call" && typeof obj.name === "string") {
          const name = obj.name;
          // Extract a short hint from the input (file path, command, etc.)
          const input = obj.input as Record<string, unknown> | undefined;
          let hint = "";
          if (input) {
            const val =
              input.file_path ?? input.command ?? input.pattern ?? input.path ?? input.query;
            if (typeof val === "string") {
              hint = val.length > 40 ? "…" + val.slice(-38) : val;
            }
          }
          return hint ? `${name}(${hint})` : name;
        }
      } catch {
        // skip non-JSON lines
      }
    }
  } catch {
    // log file not found or unreadable — not an error
  }
  return null;
}

// ── Exported helpers (used by tests) ─────────────────────────────────────

/**
 * Returns the active task backend. Exported for testing.
 * TRD-024: Always returns 'br'; sd backend removed.
 */
export function getStatusBackend(): TaskBackend {
  return 'br';
}

/**
 * Status counts returned by fetchStatusCounts.
 */
export interface StatusCounts {
  total: number;
  ready: number;
  backlog: number;
  inProgress: number;
  completed: number;
  blocked: number;
}

export interface StatusQueueItem {
  id: string;
  title: string;
  type: string;
  priority: string;
  status: string;
  parent: string | null;
  updatedAt: string;
}

export interface StatusQueueSummary {
  backlog: StatusQueueItem[];
  blocked: StatusQueueItem[];
  warnings: string[];
}

interface StatusIssueSnapshot {
  openIssues: BrIssue[];
  closedIssues: BrIssue[];
  readyIssues: Issue[];
  backlogIssues: BrIssue[];
  warnings: string[];
}
interface AggregatedQueueWarning {
  name: string;
  path: string;
  warnings: string[];
}


interface AggregatedProjectSummary {
  name: string;
  path: string;
  tasks: StatusCounts & { failed: number; stuck: number; queue: StatusQueueSummary };
  agents: { active: number };
  costs: { totalCost: number };
}

interface SkippedStatusProject {
  name: string;
  path: string;
  reason: string;
}

interface AggregatedProjectStatus {
  summary: AggregatedProjectSummary;
  counts: StatusCounts;
  failed: number;
  stuck: number;
  activeAgents: number;
  totalCost: number;
}

interface ActiveRunEntry {
  run: Run;
  progress: RunProgress | null;
}

interface StaleSdkRunEntry extends ActiveRunEntry {
  health: SdkRunHealth;
}

interface ClassifiedActiveRuns {
  active: ActiveRunEntry[];
  staleSdk: StaleSdkRunEntry[];
}

function classifyActiveRuns(store: ForemanStore, runs: Run[]): ClassifiedActiveRuns {
  const active: ActiveRunEntry[] = [];
  const staleSdk: StaleSdkRunEntry[] = [];

  for (const run of runs) {
    const progress = store.getRunProgress(run.id);
    const health = getSdkRunHealth(run, progress);
    if (health.isStale) {
      staleSdk.push({ run, progress, health });
      continue;
    }

    active.push({ run, progress });
  }

  return { active, staleSdk };
}

function describeStaleSdkRun(entry: StaleSdkRunEntry): string {
  const lastSeen = entry.health.lastActivityAt
    ? `${elapsed(entry.health.lastActivityAt)} ago`
    : "unknown last activity";

  return `${entry.run.seed_id} is recorded as running, but SDK activity is stale (${lastSeen}; threshold ${entry.health.staleThresholdHours}h).`;
}

function serializeStaleSdkRun(entry: StaleSdkRunEntry): Omit<Run, "progress"> & {
  progress: RunProgress | null;
  staleReason: string;
  lastActivityAt: string | null;
  staleThresholdHours: number;
} {
  return {
    ...entry.run,
    progress: entry.progress,
    staleReason: describeStaleSdkRun(entry),
    lastActivityAt: entry.health.lastActivityAt,
    staleThresholdHours: entry.health.staleThresholdHours,
  };
}


function collectStatusJsonWarnings(opts: { json?: boolean; watch?: boolean | string; live?: boolean }): string[] {
  if (!opts.json) return [];

  const warnings: string[] = [];

  if (opts.live) {
    warnings.push("--live is ignored when --json is used; status returns a single snapshot.");
  }

  if (opts.watch !== undefined) {
    warnings.push("--watch is ignored when --json is used; status returns a single snapshot.");
  }

  for (const warning of warnings) {
    console.warn(`Warning: ${warning}`);
  }

  return warnings;
}


function parseQueuePriority(priority: string | number): number {
  return normalizePriority(priority);
}

function sortQueueIssues(issues: BrIssue[]): BrIssue[] {
  return [...issues].sort((a, b) => {
    const priorityDelta = parseQueuePriority(a.priority) - parseQueuePriority(b.priority);
    if (priorityDelta !== 0) return priorityDelta;

    const ageDelta = new Date(a.updated_at).getTime() - new Date(b.updated_at).getTime();
    if (ageDelta !== 0) return ageDelta;

    return a.id.localeCompare(b.id);
  });
}

function toStatusQueueItem(issue: BrIssue): StatusQueueItem {
  return {
    id: issue.id,
    title: issue.title,
    type: issue.type,
    priority: formatPriorityLabel(issue.priority),
    status: issue.status,
    parent: issue.parent,
    updatedAt: issue.updated_at,
  };
}

async function fetchStatusIssueSnapshot(projectPath: string): Promise<StatusIssueSnapshot> {
  const brClient = new BeadsRustClient(projectPath);
  const warnings: string[] = [];

  let openIssues: BrIssue[] = [];
  try {
    openIssues = await brClient.list();
  } catch (error) {
    warnings.push(`open issues unavailable: ${error instanceof Error ? error.message : String(error)}`);
  }

  let closedIssues: BrIssue[] = [];
  try {
    closedIssues = await brClient.list({ status: "closed" });
  } catch (error) {
    warnings.push(`closed issues unavailable: ${error instanceof Error ? error.message : String(error)}`);
  }

  let readyIssues: Issue[] = [];
  try {
    readyIssues = await brClient.ready();
  } catch (error) {
    warnings.push(`ready queue unavailable: ${error instanceof Error ? error.message : String(error)}`);
  }

  let backlogIssues: BrIssue[] = [];
  try {
    backlogIssues = await brClient.listBacklog();
  } catch (error) {
    warnings.push(`backlog queue unavailable: ${error instanceof Error ? error.message : String(error)}`);
  }

  return { openIssues, closedIssues, readyIssues, backlogIssues, warnings };
}

function buildStatusCounts(snapshot: StatusIssueSnapshot): StatusCounts {
  const inProgress = snapshot.openIssues.filter((i) => i.status === "in_progress").length;
  const completed = snapshot.closedIssues.length;
  const ready = snapshot.readyIssues.length;
  const backlog = snapshot.backlogIssues.length;
  const readyIds = new Set(snapshot.readyIssues.map((i) => i.id));
  const backlogIds = new Set(snapshot.backlogIssues.map((i) => i.id));
  const blocked = snapshot.openIssues.filter(
    (i) => i.status !== "in_progress" && !readyIds.has(i.id) && !backlogIds.has(i.id),
  ).length;
  const total = snapshot.openIssues.length + completed;

  return { total, ready, backlog, inProgress, completed, blocked };
}

function buildStatusQueueSummary(snapshot: StatusIssueSnapshot): StatusQueueSummary {
  const readyIds = new Set(snapshot.readyIssues.map((i) => i.id));
  const backlogIds = new Set(snapshot.backlogIssues.map((i) => i.id));
  const blockedIssues = snapshot.openIssues.filter(
    (issue) => issue.status !== "in_progress" && !readyIds.has(issue.id) && !backlogIds.has(issue.id),
  );

  return {
    backlog: sortQueueIssues(snapshot.backlogIssues).map(toStatusQueueItem),
    blocked: sortQueueIssues(blockedIssues).map(toStatusQueueItem),
    warnings: snapshot.warnings,
  };
}

/**
 * Fetch task status counts using the br backend.
 *
 * TRD-024: sd backend removed. Always uses BeadsRustClient (br CLI).
 */
export async function fetchStatusCounts(projectPath: string): Promise<StatusCounts> {
  const snapshot = await fetchStatusIssueSnapshot(projectPath);
  return buildStatusCounts(snapshot);
}

export async function fetchStatusQueueSummary(projectPath: string): Promise<StatusQueueSummary> {
  const snapshot = await fetchStatusIssueSnapshot(projectPath);
  return buildStatusQueueSummary(snapshot);
}

async function fetchAggregatedProjectStatus(name: string, projectPath: string): Promise<AggregatedProjectStatus> {
  const snapshot = await fetchStatusIssueSnapshot(projectPath);
  const counts = buildStatusCounts(snapshot);
  const queue = buildStatusQueueSummary(snapshot);

  const store = ForemanStore.forProject(projectPath);
  try {
    const project = store.getProjectByPath(projectPath);

    let failed = 0;
    let stuck = 0;
    let activeAgentCount = 0;
    let projectCost = 0;

    if (project) {
      const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
      failed = store.getRunsByStatusSince("failed", since, project.id).length;
      stuck = store.getRunsByStatusSince("stuck", since, project.id).length;
      activeAgentCount = classifyActiveRuns(store, store.getActiveRuns(project.id)).active.length;
      projectCost = store.getMetrics(project.id).totalCost;
    }

    return {
      summary: {
        name,
        path: projectPath,
        tasks: { ...counts, failed, stuck, queue },
        agents: { active: activeAgentCount },
        costs: { totalCost: projectCost },
      },
      counts,
      failed,
      stuck,
      activeAgents: activeAgentCount,
      totalCost: projectCost,
    };
  } finally {
    store.close();
  }
}

// ── Internal render helper ────────────────────────────────────────────────

async function renderStatus(projectPath: string): Promise<void> {
  let counts: StatusCounts = { total: 0, ready: 0, backlog: 0, inProgress: 0, completed: 0, blocked: 0 };
  try {
    counts = await fetchStatusCounts(projectPath);
  } catch (err) {
    console.error(chalk.red(err instanceof Error ? err.message : String(err)));
    process.exit(1);
  }

  const { total, ready, backlog, inProgress, completed, blocked } = counts;

  console.log(chalk.bold("Tasks"));
  console.log(`  Total:       ${chalk.white(total)}`);
  console.log(`  Ready:       ${chalk.green(ready)}`);
  if (backlog > 0) console.log(`  Backlog:     ${chalk.dim(backlog)}`);
  console.log(`  In Progress: ${chalk.yellow(inProgress)}`);
  console.log(`  Completed:   ${chalk.cyan(completed)}`);
  console.log(`  Blocked:     ${chalk.red(blocked)}`);

  // Show active agents from sqlite
  const store = ForemanStore.forProject(projectPath);
  const project = store.getProjectByPath(projectPath);

  // Show failed/stuck run counts and success rate from SQLite (only recent — last 24h)
  if (project) {
    const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
    const failedCount = store.getRunsByStatusSince("failed", since, project.id).length;
    const stuckCount = store.getRunsByStatusSince("stuck", since, project.id).length;
    if (failedCount > 0) console.log(`  Failed:      ${chalk.red(failedCount)} ${chalk.dim("(last 24h)")}`);
    if (stuckCount > 0) console.log(`  Stuck:       ${chalk.red(stuckCount)} ${chalk.dim("(last 24h)")}`);

    const sr = store.getSuccessRate(project.id);
    console.log(`  Success Rate (24h): ${formatSuccessRate(sr.rate)}${sr.rate === null ? chalk.dim(" (need 3+ runs)") : ""}`);
  }

  console.log();
  console.log(chalk.bold("Active Agents"));

  if (project) {
    const activeRuns = classifyActiveRuns(store, store.getActiveRuns(project.id));
    if (activeRuns.active.length === 0) {
      console.log(chalk.dim("  (no agents running)"));
    } else {
      for (let i = 0; i < activeRuns.active.length; i++) {
        const { run, progress } = activeRuns.active[i];

        // Fetch run history to show attempt count and previous outcome
        const allRuns = store.getRunsForSeed(run.seed_id, project.id);
        const attemptNumber = allRuns.length > 1 ? allRuns.length : undefined;
        const previousRun = allRuns.length > 1 ? allRuns[1] : null;
        const previousStatus = previousRun?.status;

        console.log(renderAgentCard(run, progress, true, undefined, attemptNumber, previousStatus));
        // For running agents, show last Pi activity from the .out log file
        if (run.status === "running") {
          const lastActivity = await getLastPiActivity(run.id);
          if (lastActivity) {
            console.log(`  ${chalk.dim("Last tool  ")} ${chalk.dim(lastActivity)}`);
          }
        }
        // Separate cards with a blank line, but don't add a trailing blank
        // after the last card (avoids a dangling empty line in single-agent output).
        if (i < activeRuns.active.length - 1) console.log();
      }
    }

    if (activeRuns.staleSdk.length > 0) {
      console.log();
      console.log(chalk.bold("Stale Active Runs"));
      for (let i = 0; i < activeRuns.staleSdk.length; i++) {
        const { run, progress } = activeRuns.staleSdk[i];
        const staleRun: Run = { ...run, status: "stuck", completed_at: run.completed_at ?? new Date().toISOString() };
        console.log(renderAgentCard(staleRun, progress, true));
        console.log(`  ${chalk.yellow("Stale     ")} ${chalk.yellow(describeStaleSdkRun(activeRuns.staleSdk[i]))}`);
        console.log(`  ${chalk.dim("Recovery  ")} ${chalk.dim("Run 'foreman doctor --fix' to reconcile this stale SDK run.")}`);
        if (i < activeRuns.staleSdk.length - 1) console.log();
      }
    }


    // Cost summary
    const metrics = store.getMetrics(project.id);
    if (metrics.totalCost > 0) {
      console.log();
      console.log(chalk.bold("Costs"));
      console.log(`  Total: ${chalk.yellow(`$${metrics.totalCost.toFixed(2)}`)}`);
      console.log(`  Tokens: ${chalk.dim(`${(metrics.totalTokens / 1000).toFixed(1)}k`)}`);

      // Per-phase cost breakdown
      if (metrics.costByPhase && Object.keys(metrics.costByPhase).length > 0) {
        console.log(`  ${chalk.dim("By phase:")}`);
        const phaseOrder = ["explorer", "developer", "qa", "reviewer"];
        const phases = Object.entries(metrics.costByPhase)
          .sort(([a], [b]) => {
            const ai = phaseOrder.indexOf(a);
            const bi = phaseOrder.indexOf(b);
            if (ai === -1 && bi === -1) return a.localeCompare(b);
            if (ai === -1) return 1;
            if (bi === -1) return -1;
            return ai - bi;
          });
        for (const [phase, cost] of phases) {
          console.log(`    ${phase.padEnd(12)} ${chalk.yellow(`$${cost.toFixed(4)}`)}`);
        }
      }

      // Per-agent/model cost breakdown
      if (metrics.agentCostBreakdown && Object.keys(metrics.agentCostBreakdown).length > 0) {
        console.log(`  ${chalk.dim("By model:")}`);
        const sorted = Object.entries(metrics.agentCostBreakdown).sort(([, a], [, b]) => b - a);
        for (const [model, cost] of sorted) {
          console.log(`    ${model.padEnd(32)} ${chalk.yellow(`$${cost.toFixed(4)}`)}`);
        }
      }
    }
  } else {
    console.log(chalk.dim("  (project not registered — run 'foreman init')"));
  }

  store.close();
}

// ── Live status header (used by --live mode) ─────────────────────────────

/**
 * Render a compact task-count header for use in the live dashboard view.
 * Shows br task counts (ready, backlog, in-progress, blocked, completed) as a
 * one-line summary suitable for prepending to the dashboard display.
 */
export function renderLiveStatusHeader(counts: StatusCounts): string {
  const { total, ready, backlog, inProgress, completed, blocked } = counts;
  const parts: string[] = [
    chalk.bold("Tasks:"),
    `total ${chalk.white(total)}`,
    `ready ${chalk.green(ready)}`,
  ];
  if (backlog > 0) parts.push(`backlog ${chalk.dim(backlog)}`);
  parts.push(
    `in-progress ${chalk.yellow(inProgress)}`,
    `completed ${chalk.cyan(completed)}`,
  );
  if (blocked > 0) parts.push(`blocked ${chalk.red(blocked)}`);
  return parts.join("  ");
}

export const statusCommand = new Command("status")
  .description("Show control-plane status across registered projects or one scoped project")
  .option("-w, --watch [seconds]", "Refresh every N seconds (default: 10)")
  .option("--live", "Enable full dashboard TUI with event stream (implies --watch; use instead of 'foreman dashboard')")
  .option("--json", "Output status as JSON")
  .option("--all", "Show control-plane summary across all registered projects")
  .option("--project <name>", "Scope status to one registered project")
  .option("--project-path <absolute-path>", "Scope status to one explicit project path (advanced/script usage)")
  .action(async (opts: { watch?: boolean | string; json?: boolean; live?: boolean; project?: string; projectPath?: string; all?: boolean }) => {
    const jsonWarnings = collectStatusJsonWarnings(opts);

    if (opts.all) {
      const registry = new ProjectRegistry();
      const projects = registry.list();

      if (projects.length === 0) {
        if (opts.json) {
          console.log(JSON.stringify({
            projects: [],
            summary: null,
            warning: "No registered projects found. Run 'foreman project add' to register projects.",
            warnings: jsonWarnings,
          }, null, 2));
        } else {
          console.log(chalk.yellow("No registered projects found. Run 'foreman project add' to register projects."));
        }
        return;
      }

      const aggregated: StatusCounts = { total: 0, ready: 0, backlog: 0, inProgress: 0, completed: 0, blocked: 0 };
      let totalFailed = 0;
      let totalStuck = 0;
      let totalActiveAgents = 0;
      let totalCost = 0;
      const projectSummaries: AggregatedProjectSummary[] = [];
      const skippedProjects: SkippedStatusProject[] = [];
      const queueWarnings: AggregatedQueueWarning[] = [];

      for (const proj of projects) {
        try {
          const projectStatus = await fetchAggregatedProjectStatus(proj.name, proj.path);
          aggregated.total += projectStatus.counts.total;
          aggregated.ready += projectStatus.counts.ready;
          aggregated.backlog += projectStatus.counts.backlog;
          aggregated.inProgress += projectStatus.counts.inProgress;
          aggregated.completed += projectStatus.counts.completed;
          aggregated.blocked += projectStatus.counts.blocked;
          totalFailed += projectStatus.failed;
          totalStuck += projectStatus.stuck;
          totalActiveAgents += projectStatus.activeAgents;
          totalCost += projectStatus.totalCost;
          projectSummaries.push(projectStatus.summary);
          if (projectStatus.summary.tasks.queue.warnings.length > 0) {
            queueWarnings.push({
              name: projectStatus.summary.name,
              path: projectStatus.summary.path,
              warnings: [...projectStatus.summary.tasks.queue.warnings],
            });
          }
        } catch (error) {
          skippedProjects.push({
            name: proj.name,
            path: proj.path,
            reason: error instanceof Error ? error.message : String(error),
          });
        }
      }

      if (opts.json) {
        console.log(JSON.stringify({
          projects: projectSummaries,
          skippedProjects,
          queueWarnings,
          warnings: jsonWarnings,
          summary: {
            tasks: aggregated,
            failed: totalFailed,
            stuck: totalStuck,
            activeAgents: totalActiveAgents,
            totalCost,
            projects: {
              totalRegistered: projects.length,
              reported: projectSummaries.length,
              skipped: skippedProjects.length,
            },
          },
        }, null, 2));
        return;
      }

      console.log(chalk.bold("Tasks (All Projects)"));
      console.log(`  Total:       ${chalk.white(aggregated.total)}`);
      console.log(`  Ready:       ${chalk.green(aggregated.ready)}`);
      if (aggregated.backlog > 0) console.log(`  Backlog:     ${chalk.dim(aggregated.backlog)}`);
      console.log(`  In Progress: ${chalk.yellow(aggregated.inProgress)}`);
      console.log(`  Completed:   ${chalk.cyan(aggregated.completed)}`);
      console.log(`  Blocked:     ${chalk.red(aggregated.blocked)}`);
      console.log();
      console.log(chalk.bold("Summary (All Projects)"));
      if (totalFailed > 0) console.log(`  Failed (24h): ${chalk.red(totalFailed)}`);
      if (totalStuck > 0) console.log(`  Stuck (24h):  ${chalk.red(totalStuck)}`);
      console.log(`  Active Agents: ${chalk.yellow(totalActiveAgents)}`);
      if (totalCost > 0) console.log(`  Total Cost:   ${chalk.yellow(`$${totalCost.toFixed(2)}`)}`);
      if (skippedProjects.length > 0) console.log(`  Skipped:      ${chalk.yellow(skippedProjects.length)}`);
      console.log();
      if (projectSummaries.length > 0) {
        console.log(chalk.dim(`Projects: ${projectSummaries.map((p) => p.name).join(", ")}`));
      }
      if (skippedProjects.length > 0) {
        console.log(chalk.yellow(`Skipped Projects: ${skippedProjects.map((p) => p.name).join(", ")}`));
      }
      if (queueWarnings.length > 0) {
        console.log(chalk.yellow("Queue Warnings:"));
        for (const entry of queueWarnings) {
          console.log(chalk.yellow(`  ${entry.name}:`));
          for (const warning of entry.warnings) {
            console.log(chalk.dim(`    ${warning}`));
          }
        }
      }
      return;
    }

    const projectPath = await resolveRepoRootProjectPath(opts, Boolean(opts.json));
    if (opts.json) {
      // JSON output path — gather data and serialize
      try {
        const snapshot = await fetchStatusIssueSnapshot(projectPath);
        const counts = buildStatusCounts(snapshot);
        const queue = buildStatusQueueSummary(snapshot);

        const store = ForemanStore.forProject(projectPath);
        const project = store.getProjectByPath(projectPath);

        let failed = 0;
        let stuck = 0;
        let activeRuns: Array<{ run: Run; progress: RunProgress | null }> = [];
        let staleRuns: Array<ReturnType<typeof serializeStaleSdkRun>> = [];
        let metrics: Metrics = { totalCost: 0, totalTokens: 0, tasksByStatus: {}, costByRuntime: [] };
        let successRateData: { rate: number | null; merged: number; failed: number } = { rate: null, merged: 0, failed: 0 };

        if (project) {
          const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
          failed = store.getRunsByStatusSince("failed", since, project.id).length;
          stuck = store.getRunsByStatusSince("stuck", since, project.id).length;
          const classifiedRuns = classifyActiveRuns(store, store.getActiveRuns(project.id));
          activeRuns = classifiedRuns.active;
          staleRuns = classifiedRuns.staleSdk.map(serializeStaleSdkRun);
          metrics = store.getMetrics(project.id);
          successRateData = store.getSuccessRate(project.id);
          jsonWarnings.push(...classifiedRuns.staleSdk.map(describeStaleSdkRun));
        }
        store.close();

        const output = {
          tasks: {
            total: counts.total,
            ready: counts.ready,
            backlog: counts.backlog,
            inProgress: counts.inProgress,
            completed: counts.completed,
            blocked: counts.blocked,
            failed,
            stuck,
            queue,
          },
          successRate: {
            rate: successRateData.rate,
            merged: successRateData.merged,
            failed: successRateData.failed,
          },
          agents: {
            active: activeRuns.map(({ run, progress }) => ({ ...run, progress })),
            stale: staleRuns,
          },
          costs: {
            totalCost: metrics.totalCost,
            totalTokens: metrics.totalTokens,
            byPhase: metrics.costByPhase ?? {},
            byModel: metrics.agentCostBreakdown ?? {},
          },
          warnings: jsonWarnings,
        };

        console.log(JSON.stringify(output, null, 2));
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        console.error(JSON.stringify({ error: message }));
        process.exit(1);
      }
      return;
    }

    if (opts.live) {
      // ── Full dashboard TUI mode (--live) ─────────────────────────────────
      // Combines br task counts with the dashboard's multi-project display,
      // event timeline, and recently-completed agents.
      const interval = typeof opts.watch === "string" ? parseInt(opts.watch, 10) : 3;
      const seconds = Number.isFinite(interval) && interval > 0 ? interval : 3;

      let detached = false;
      const onSigint = () => {
        if (detached) return;
        detached = true;
        process.stdout.write("\x1b[?25h\n");
        console.log(chalk.dim("  Detached — agents continue in background."));
        console.log(chalk.dim("  Check status: foreman status"));
        process.exit(0);
      };
      process.on("SIGINT", onSigint);
      process.stdout.write("\x1b[?25l"); // hide cursor

      try {
        while (!detached) {
          const store = ForemanStore.forProject(projectPath);

          let counts: StatusCounts = { total: 0, ready: 0, backlog: 0, inProgress: 0, completed: 0, blocked: 0 };
          try {
            counts = await fetchStatusCounts(projectPath);
          } catch { /* br not available — show zero counts */ }

          const dashState = pollDashboard(store, undefined, 8);
          store.close();

          const taskLine = renderLiveStatusHeader(counts);
          const dashDisplay = renderDashboard(dashState);

          // Prepend the task-count line to the dashboard display.
          // Insert it after the first line (the "Foreman Dashboard" header).
          const dashLines = dashDisplay.split("\n");
          // Insert task counts as second line (index 1), shifting the rule down.
          dashLines.splice(1, 0, taskLine);
          const combined = dashLines.join("\n");

          process.stdout.write("\x1B[2J\x1B[H" + combined + "\n");
          await new Promise<void>((r) => setTimeout(r, seconds * 1000));
        }
      } finally {
        process.stdout.write("\x1b[?25h");
        process.removeListener("SIGINT", onSigint);
      }
      return;
    }

    if (opts.watch !== undefined) {
      const interval = typeof opts.watch === "string" ? parseInt(opts.watch, 10) : 10;
      const seconds = Number.isFinite(interval) && interval > 0 ? interval : 10;

      // Keep process alive and handle Ctrl+C gracefully
      process.on("SIGINT", () => {
        process.stdout.write("\x1b[?25h"); // restore cursor
        process.exit(0);
      });

      process.stdout.write("\x1b[?25l"); // hide cursor
      while (true) {
        // Clear screen and move cursor to top
        process.stdout.write("\x1b[2J\x1b[H");
        console.log(chalk.bold("Project Status") + chalk.dim(`  (watching every ${seconds}s — Ctrl+C to stop)\n`));
        await renderStatus(projectPath);
        console.log(chalk.dim(`\nLast updated: ${new Date().toLocaleTimeString()}`));
        await new Promise((r) => setTimeout(r, seconds * 1000));
      }
    } else {
      console.log(chalk.bold("Project Status\n"));
      await renderStatus(projectPath);
    }
  });
