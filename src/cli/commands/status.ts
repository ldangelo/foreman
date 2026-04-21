import { Command } from "commander";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { homedir } from "node:os";
import chalk from "chalk";
import { ForemanStore } from "../../lib/store.js";
import type { Metrics, Run, RunProgress } from "../../lib/store.js";
import { renderAgentCard, formatSuccessRate } from "../watch-ui.js";
import type { TaskBackend } from "../../lib/feature-flags.js";
import { fetchTaskCounts } from "../../lib/task-client-factory.js";
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
  inProgress: number;
  completed: number;
  blocked: number;
}

/**
 * Fetch task status counts using the shared task backend selector.
 */
export async function fetchStatusCounts(projectPath: string): Promise<StatusCounts> {
  return fetchTaskCounts(projectPath);
}

// ── Internal render helper ────────────────────────────────────────────────

async function renderStatus(projectPath: string): Promise<void> {
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
    const activeRuns = store.getActiveRuns(project.id);
    if (activeRuns.length === 0) {
      console.log(chalk.dim("  (no agents running)"));
    } else {
      for (let i = 0; i < activeRuns.length; i++) {
        const run = activeRuns[i];
        const progress = store.getRunProgress(run.id);

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

// ── Live status header (used by --live mode) ─────────────────────────────

/**
 * Render a compact task-count header for use in the live dashboard view.
 * Shows br task counts (ready, in-progress, blocked, completed) as a
 * one-line summary suitable for prepending to the dashboard display.
 */
export function renderLiveStatusHeader(counts: StatusCounts): string {
  const { total, ready, inProgress, completed, blocked } = counts;
  const parts: string[] = [
    chalk.bold("Tasks:"),
    `total ${chalk.white(total)}`,
    `ready ${chalk.green(ready)}`,
    `in-progress ${chalk.yellow(inProgress)}`,
    `completed ${chalk.cyan(completed)}`,
  ];
  if (blocked > 0) parts.push(`blocked ${chalk.red(blocked)}`);
  return parts.join("  ");
}

export const statusCommand = new Command("status")
  .description("Show project status from beads_rust (br) + sqlite")
  .option("-w, --watch [seconds]", "Refresh every N seconds (default: 10)")
  .option("--live", "Enable full dashboard TUI with event stream (implies --watch; use instead of 'foreman dashboard')")
  .option("--json", "Output status as JSON")
  .option("--all", "Show status across all registered projects")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(async (opts: { watch?: boolean | string; json?: boolean; live?: boolean; project?: string; projectPath?: string; all?: boolean }) => {
    if (opts.all) {
      const registry = new ProjectRegistry();
      const projects = await registry.list();

      if (projects.length === 0) {
        console.log(chalk.yellow("No registered projects found. Run 'foreman project add' to register projects."));
        return;
      }

      const aggregated: StatusCounts = { total: 0, ready: 0, inProgress: 0, completed: 0, blocked: 0 };
      let totalFailed = 0;
      let totalStuck = 0;
      let totalActiveAgents = 0;
      let totalCost = 0;

      for (const proj of projects) {
        try {
          const counts = await fetchStatusCounts(proj.path);
          aggregated.total += counts.total;
          aggregated.ready += counts.ready;
          aggregated.inProgress += counts.inProgress;
          aggregated.completed += counts.completed;
          aggregated.blocked += counts.blocked;

          const store = ForemanStore.forProject(proj.path);
          const project = store.getProjectByPath(proj.path);
          if (project) {
            const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
            totalFailed += store.getRunsByStatusSince("failed", since, project.id).length;
            totalStuck += store.getRunsByStatusSince("stuck", since, project.id).length;
            totalActiveAgents += store.getActiveRuns(project.id).length;
            totalCost += store.getMetrics(project.id).totalCost;
          }
          store.close();
        } catch {
          // Ignore stale/inaccessible projects in aggregated status.
        }
      }

      console.log(chalk.bold("Tasks (All Projects)"));
      console.log(`  Total:       ${chalk.white(aggregated.total)}`);
      console.log(`  Ready:       ${chalk.green(aggregated.ready)}`);
      console.log(`  In Progress: ${chalk.yellow(aggregated.inProgress)}`);
      console.log(`  Completed:   ${chalk.cyan(aggregated.completed)}`);
      console.log(`  Blocked:     ${chalk.red(aggregated.blocked)}`);
      console.log();
      console.log(chalk.bold("Summary (All Projects)"));
      if (totalFailed > 0) console.log(`  Failed (24h): ${chalk.red(totalFailed)}`);
      if (totalStuck > 0) console.log(`  Stuck (24h):  ${chalk.red(totalStuck)}`);
      console.log(`  Active Agents: ${chalk.yellow(totalActiveAgents)}`);
      if (totalCost > 0) console.log(`  Total Cost:   ${chalk.yellow(`$${totalCost.toFixed(2)}`)}`);
      console.log();
      console.log(chalk.dim(`Projects: ${projects.map((p) => p.name).join(", ")}`));
      return;
    }

    const projectPath = await resolveRepoRootProjectPath(opts);
    if (opts.json) {
      // JSON output path — gather data and serialize
      try {
        let counts: StatusCounts = { total: 0, ready: 0, inProgress: 0, completed: 0, blocked: 0 };
        try {
          counts = await fetchStatusCounts(projectPath);
        } catch { /* return zeros on error */ }

        const store = ForemanStore.forProject(projectPath);
        const project = store.getProjectByPath(projectPath);

        let failed = 0;
        let stuck = 0;
        let activeRuns: Array<{ run: Run; progress: RunProgress | null }> = [];
        let metrics: Metrics = { totalCost: 0, totalTokens: 0, tasksByStatus: {}, costByRuntime: [] };
        let successRateData: { rate: number | null; merged: number; failed: number } = { rate: null, merged: 0, failed: 0 };

        if (project) {
          const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
          failed = store.getRunsByStatusSince("failed", since, project.id).length;
          stuck = store.getRunsByStatusSince("stuck", since, project.id).length;
          const runs = store.getActiveRuns(project.id);
          activeRuns = runs.map((run) => ({ run, progress: store.getRunProgress(run.id) }));
          metrics = store.getMetrics(project.id);
          successRateData = store.getSuccessRate(project.id);
        }

        store.close();

        const output = {
          tasks: {
            total: counts.total,
            ready: counts.ready,
            inProgress: counts.inProgress,
            completed: counts.completed,
            blocked: counts.blocked,
            failed,
            stuck,
          },
          successRate: {
            rate: successRateData.rate,
            merged: successRateData.merged,
            failed: successRateData.failed,
          },
          agents: {
            active: activeRuns.map(({ run, progress }) => ({ ...run, progress })),
          },
          costs: {
            totalCost: metrics.totalCost,
            totalTokens: metrics.totalTokens,
            byPhase: metrics.costByPhase ?? {},
            byModel: metrics.agentCostBreakdown ?? {},
          },
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

          let counts: StatusCounts = { total: 0, ready: 0, inProgress: 0, completed: 0, blocked: 0 };
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
