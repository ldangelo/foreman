import chalk from "chalk";

import type { Event, ForemanStore, Project, Run, RunProgress } from "../lib/store.js";
import { elapsed, renderAgentCard, shortPath } from "./watch-ui.js";

// ── Types ─────────────────────────────────────────────────────────────────

export interface DashboardState {
  project: Project | null;
  runs: Array<{ run: Run; progress: RunProgress | null }>;
  summary: {
    totalCost: number;
    totalTools: number;
    totalFiles: number;
    completedCount: number;
    failedCount: number;
    stuckCount: number;
    runningCount: number;
    pendingCount: number;
  };
  recentEvents: Event[];
  updatedAt: string; // ISO timestamp of last poll
}

// ── Constants ─────────────────────────────────────────────────────────────

const RULE = chalk.dim("━".repeat(70));
const THIN_RULE = chalk.dim("─".repeat(70));

const EVENT_ICONS: Record<string, string> = {
  dispatch: chalk.blue("→"),
  claim: chalk.cyan("⊙"),
  complete: chalk.green("✓"),
  fail: chalk.red("✗"),
  merge: chalk.green("⊕"),
  stuck: chalk.yellow("⚠"),
  restart: chalk.blue("↻"),
  recover: chalk.yellow("↺"),
  conflict: chalk.red("⊘"),
  "test-fail": chalk.red("⊘"),
  "pr-created": chalk.cyan("⌥"),
};

// ── Rendering helpers ──────────────────────────────────────────────────────

function renderHeader(project: Project | null, updatedAt: string): string {
  const now = new Date(updatedAt).toLocaleTimeString();
  const projectLabel = project
    ? `${chalk.bold(project.name)} ${chalk.dim(shortPath(project.path))}`
    : chalk.dim("(all projects)");
  return [
    `${chalk.bold.cyan("Foreman Dashboard")}  ${projectLabel}  ${chalk.dim("updated " + now)}`,
    RULE,
  ].join("\n");
}

function renderSummaryBar(summary: DashboardState["summary"]): string {
  const parts: string[] = [];
  if (summary.runningCount > 0) parts.push(chalk.blue(`${summary.runningCount} running`));
  if (summary.pendingCount > 0) parts.push(chalk.gray(`${summary.pendingCount} pending`));
  if (summary.completedCount > 0) parts.push(chalk.green(`${summary.completedCount} completed`));
  if (summary.failedCount > 0) parts.push(chalk.red(`${summary.failedCount} failed`));
  if (summary.stuckCount > 0) parts.push(chalk.yellow(`${summary.stuckCount} stuck`));

  const statusStr = parts.length > 0 ? parts.join("  ") : chalk.dim("no agents");
  const metricsStr = [
    `${summary.totalTools} tools`,
    chalk.yellow(`${summary.totalFiles} files`),
    chalk.green(`$${summary.totalCost.toFixed(4)}`),
  ].join("  ");

  return `${statusStr}  ${chalk.dim("│")}  ${metricsStr}`;
}

function renderEventLine(event: Event): string {
  const icon = EVENT_ICONS[event.event_type] ?? chalk.dim("·");
  const age = elapsed(event.created_at);
  const detail = event.details
    ? (() => {
        try {
          const parsed = JSON.parse(event.details) as Record<string, unknown>;
          if (parsed.beadId) return chalk.cyan(String(parsed.beadId));
          return chalk.dim(event.details.slice(0, 40));
        } catch {
          return chalk.dim(event.details.slice(0, 40));
        }
      })()
    : "";
  return `  ${icon} ${chalk.dim(event.event_type.padEnd(10))} ${detail}  ${chalk.dim(age)}`;
}

export function renderEventLog(events: Event[], limit = 15): string {
  if (events.length === 0) {
    return chalk.dim("  (no events yet)");
  }
  const shown = events.slice(0, limit);
  return shown.map(renderEventLine).join("\n");
}

export function renderAgentsList(
  runs: DashboardState["runs"],
): string {
  if (runs.length === 0) {
    return chalk.dim("  (no agents running)");
  }
  return runs.map(({ run, progress }) => renderAgentCard(run, progress)).join("\n\n");
}

export function renderDashboard(state: DashboardState, showDetachHint = true): string {
  const lines: string[] = [];

  // Header
  lines.push(renderHeader(state.project, state.updatedAt));
  lines.push("");

  // Agent cards section
  const activeRuns = state.runs.filter(
    (r) => r.run.status === "running" || r.run.status === "pending",
  );
  const finishedRuns = state.runs.filter(
    (r) => r.run.status !== "running" && r.run.status !== "pending",
  );

  if (activeRuns.length > 0) {
    lines.push(chalk.bold("Active Agents"));
    lines.push(THIN_RULE);
    lines.push(renderAgentsList(activeRuns));
    lines.push("");
  }

  if (finishedRuns.length > 0) {
    lines.push(chalk.bold("Recent Agents"));
    lines.push(THIN_RULE);
    lines.push(renderAgentsList(finishedRuns));
    lines.push("");
  }

  if (activeRuns.length === 0 && finishedRuns.length === 0) {
    lines.push(chalk.dim("No agents found for this project."));
    lines.push("");
  }

  // Events log section
  if (state.recentEvents.length > 0) {
    lines.push(chalk.bold("Recent Events"));
    lines.push(THIN_RULE);
    lines.push(renderEventLog(state.recentEvents));
    lines.push("");
  }

  // Summary bar
  lines.push(RULE);
  lines.push(renderSummaryBar(state.summary));

  // Detach hint
  if (showDetachHint && state.summary.runningCount + state.summary.pendingCount > 0) {
    lines.push(chalk.dim("  Press Ctrl+C to exit — agents continue in background"));
  }

  return lines.join("\n");
}

// ── Polling ───────────────────────────────────────────────────────────────

export function pollDashboard(
  store: ForemanStore,
  projectId: string | null,
): DashboardState {
  // Get project if we have an ID
  const project = projectId ? store.getProject(projectId) : null;

  // Get all runs for this project (active + recent completed/failed)
  const activeRuns = store.getActiveRuns(projectId ?? undefined);
  const completedRuns = projectId
    ? store.getRunsByStatus("completed", projectId).slice(0, 5)
    : store.getRunsByStatus("completed").slice(0, 5);
  const failedRuns = projectId
    ? store.getRunsByStatus("failed", projectId).slice(0, 3)
    : store.getRunsByStatus("failed").slice(0, 3);

  // Merge and deduplicate (active first, then recent)
  const seenIds = new Set<string>();
  const allRuns: Run[] = [];
  for (const run of [...activeRuns, ...completedRuns, ...failedRuns]) {
    if (!seenIds.has(run.id)) {
      seenIds.add(run.id);
      allRuns.push(run);
    }
  }

  // Fetch progress for each run
  const runEntries = allRuns.map((run) => ({
    run,
    progress: store.getRunProgress(run.id),
  }));

  // Aggregate metrics
  let totalCost = 0;
  let totalTools = 0;
  let totalFiles = 0;
  for (const { progress } of runEntries) {
    if (progress) {
      totalCost += progress.costUsd;
      totalTools += progress.toolCalls;
      totalFiles += progress.filesChanged.length;
    }
  }

  const runningCount = allRuns.filter((r) => r.status === "running").length;
  const pendingCount = allRuns.filter((r) => r.status === "pending").length;
  const completedCount = allRuns.filter((r) => r.status === "completed").length;
  const failedCount = allRuns.filter(
    (r) => r.status === "failed" || r.status === "test-failed",
  ).length;
  const stuckCount = allRuns.filter((r) => r.status === "stuck").length;

  // Get recent events
  const recentEvents = store.getEvents(projectId ?? undefined, 15);

  return {
    project,
    runs: runEntries,
    summary: {
      totalCost,
      totalTools,
      totalFiles,
      completedCount,
      failedCount,
      stuckCount,
      runningCount,
      pendingCount,
    },
    recentEvents,
    updatedAt: new Date().toISOString(),
  };
}

// ── Live dashboard loop ───────────────────────────────────────────────────

export async function runDashboard(
  store: ForemanStore,
  projectId: string | null,
  intervalMs: number,
  autoUpdate: boolean,
): Promise<void> {
  let stopped = false;

  const onSigint = () => {
    if (stopped) return;
    stopped = true;
    process.stdout.write("\n");
    console.log("  Exited dashboard — agents continue in background.");
    console.log("  Check status: foreman monitor");
  };
  process.on("SIGINT", onSigint);

  try {
    do {
      const state = pollDashboard(store, projectId);
      const display = renderDashboard(state, autoUpdate);
      if (autoUpdate) {
        process.stdout.write("\x1B[2J\x1B[H" + display + "\n");
      } else {
        // Single render mode (for testing / non-interactive)
        process.stdout.write(display + "\n");
        break;
      }

      const allQuiet =
        state.summary.runningCount === 0 && state.summary.pendingCount === 0;
      if (allQuiet) break;

      await new Promise<void>((resolve) => setTimeout(resolve, intervalMs));
    } while (!stopped);
  } finally {
    process.removeListener("SIGINT", onSigint);
  }
}
