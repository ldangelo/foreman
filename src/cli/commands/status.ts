import { Command } from "commander";
import chalk from "chalk";
import { resolve } from "node:path";
import { ForemanStore } from "../../lib/store.js";
import { renderAgentCard } from "../watch-ui.js";
import { BeadsRustClient } from "../../lib/beads-rust.js";
import type { BrIssue } from "../../lib/beads-rust.js";
import type { TaskBackend } from "../../lib/feature-flags.js";
import type { Issue } from "../../lib/task-client.js";

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
  inProgress: number;
  completed: number;
  blocked: number;
}

/**
 * Fetch task status counts using the br backend.
 *
 * TRD-024: sd backend removed. Always uses BeadsRustClient (br CLI).
 */
export async function fetchStatusCounts(projectPath: string): Promise<StatusCounts> {
  const brClient = new BeadsRustClient(projectPath);

  // Fetch open issues (all non-closed)
  let openIssues: BrIssue[] = [];
  try {
    openIssues = await brClient.list();
  } catch { /* br not initialized or binary missing — return zeros */ }

  // Fetch closed issues separately (br list excludes closed by default)
  let closedIssues: BrIssue[] = [];
  try {
    closedIssues = await brClient.list({ status: "closed" });
  } catch { /* no closed issues */ }

  // Fetch ready issues (open + unblocked)
  let readyIssues: Issue[] = [];
  try {
    readyIssues = await brClient.ready();
  } catch { /* br ready may fail */ }

  const inProgress = openIssues.filter((i) => i.status === "in_progress").length;
  const completed = closedIssues.length;
  const ready = readyIssues.length;
  // blocked = open issues that are not ready and not in_progress
  const readyIds = new Set(readyIssues.map((i) => i.id));
  const blocked = openIssues.filter(
    (i) => i.status !== "in_progress" && !readyIds.has(i.id),
  ).length;
  const total = openIssues.length + completed;

  return { total, ready, inProgress, completed, blocked };
}

// ── Internal render helper ────────────────────────────────────────────────

async function renderStatus(): Promise<void> {
  const projectPath = resolve(".");
  let counts: StatusCounts = { total: 0, ready: 0, inProgress: 0, completed: 0, blocked: 0 };
  try {
    counts = await fetchStatusCounts(projectPath);
  } catch (err) {
    console.error(chalk.red(err instanceof Error ? err.message : String(err)));
    process.exit(1);
  }

  const { total, ready, inProgress, completed, blocked } = counts;

  console.log(chalk.bold("Tasks"));
  console.log(`  Total:       ${chalk.white(total)}`);
  console.log(`  Ready:       ${chalk.green(ready)}`);
  console.log(`  In Progress: ${chalk.yellow(inProgress)}`);
  console.log(`  Completed:   ${chalk.cyan(completed)}`);
  console.log(`  Blocked:     ${chalk.red(blocked)}`);

  // Show active agents from sqlite
  const store = new ForemanStore();
  const project = store.getProjectByPath(resolve("."));

  // Show failed/stuck run counts from SQLite (only recent — last 24h)
  if (project) {
    const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
    const failedCount = store.getRunsByStatusSince("failed", since, project.id).length;
    const stuckCount = store.getRunsByStatusSince("stuck", since, project.id).length;
    if (failedCount > 0) console.log(`  Failed:      ${chalk.red(failedCount)} ${chalk.dim("(last 24h)")}`);
    if (stuckCount > 0) console.log(`  Stuck:       ${chalk.red(stuckCount)} ${chalk.dim("(last 24h)")}`);
  }

  console.log();
  console.log(chalk.bold("Active Agents"));

  if (project) {
    const activeRuns = store.getActiveRuns(project.id);
    if (activeRuns.length === 0) {
      console.log(chalk.dim("  (no agents running)"));
    } else {
      for (let i = 0; i < activeRuns.length; i++) {
        const run = activeRuns[i];
        const progress = store.getRunProgress(run.id);
        console.log(renderAgentCard(run, progress));
        // Separate cards with a blank line, but don't add a trailing blank
        // after the last card (avoids a dangling empty line in single-agent output).
        if (i < activeRuns.length - 1) console.log();
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

export const statusCommand = new Command("status")
  .description("Show project status from beads_rust (br) + sqlite")
  .option("-w, --watch [seconds]", "Refresh every N seconds (default: 10)")
  .action(async (opts: { watch?: boolean | string }) => {
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
        await renderStatus();
        console.log(chalk.dim(`\nLast updated: ${new Date().toLocaleTimeString()}`));
        await new Promise((r) => setTimeout(r, seconds * 1000));
      }
    } else {
      console.log(chalk.bold("Project Status\n"));
      await renderStatus();
    }
  });
