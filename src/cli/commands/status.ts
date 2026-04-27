import { Command } from "commander";
import { readFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { homedir } from "node:os";
import chalk from "chalk";
import { createTrpcClient } from "../../lib/trpc-client.js";
import { ForemanStore } from "../../lib/store.js";
import type { Metrics, Run, RunProgress } from "../../lib/store.js";
import { renderAgentCard, formatSuccessRate, elapsed } from "../watch-ui.js";
import type { TaskBackend } from "../../lib/feature-flags.js";
import { fetchTaskCounts } from "../../lib/task-client-factory.js";
import { resolveRepoRootProjectPath, requireProjectOrAllInMultiMode } from "./project-task-support.js";
import { listRegisteredProjects } from "./project-task-support.js";
import { fetchDaemonDashboardState, pollDashboard, renderDashboard } from "./dashboard.js";

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

interface ProjectStats {
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
  bead_id: string;
  status: string;
  branch: string;
  started_at: string | null;
  queued_at: string;
  created_at: string;
}

interface DaemonStatusSnapshot {
  projectId: string;
  counts: StatusCounts;
  failed: number;
  stuck: number;
  activeRuns: DaemonRunSummary[];
}

function resolveRegisteredProject(projects: Array<{ path: string; id: string }>, projectPath: string) {
  const resolvedProjectPath = resolve(projectPath);
  return projects.find((record) => resolve(record.path) === resolvedProjectPath) ?? null;
}

export async function fetchDaemonStatusSnapshot(projectPath: string): Promise<DaemonStatusSnapshot | null> {
  try {
    const projects = await listRegisteredProjects();
    const project = resolveRegisteredProject(projects, projectPath);
    if (!project) return null;

    const client = createTrpcClient();
    const [stats, needsHuman, activeRuns] = await Promise.all([
      client.projects.stats({ projectId: project.id }) as Promise<ProjectStats>,
      client.projects.listNeedsHuman({ projectId: project.id }) as Promise<Array<{ status: string }>>,
      client.runs.listActive({ projectId: project.id }) as Promise<DaemonRunSummary[]>,
    ]);

    return {
      projectId: project.id,
      counts: {
        total: stats.tasks.total,
        ready: stats.tasks.ready,
        inProgress: stats.tasks.inProgress,
        completed: stats.tasks.merged + stats.tasks.closed,
        blocked: stats.tasks.backlog,
      },
      failed: needsHuman.filter((task) => task.status === "failed" || task.status === "conflict").length,
      stuck: needsHuman.filter((task) => task.status === "stuck").length,
      activeRuns,
    };
  } catch {
    return null;
  }
}

function renderDaemonRunCard(run: DaemonRunSummary): string {
  const since = run.started_at ?? run.queued_at ?? run.created_at;
  const time = since ? elapsed(since) : "—";
  return `${chalk.dim("▶")} ${chalk.cyan.bold(run.bead_id)} ${chalk.yellow(run.status.toUpperCase())} ${chalk.dim(time)}  ${chalk.dim(run.branch)}`;
}

/**
 * Fetch task status counts using the shared task backend selector.
 */
export async function fetchStatusCounts(projectPath: string): Promise<StatusCounts> {
  try {
    const projects = await listRegisteredProjects();
    const project = resolveRegisteredProject(projects, projectPath);
    if (project) {
      const client = createTrpcClient();
      const stats = await client.projects.stats({ projectId: project.id }) as ProjectStats;
      return {
        total: stats.tasks.total,
        ready: stats.tasks.ready,
        inProgress: stats.tasks.inProgress,
        completed: stats.tasks.merged + stats.tasks.closed,
        blocked: stats.tasks.backlog,
      };
    }
  } catch {
    // Fall back to legacy task-count path when daemon-backed project stats are unavailable.
  }

  return fetchTaskCounts(projectPath);
}

// ── Internal render helper ────────────────────────────────────────────────

async function renderStatus(projectPath: string): Promise<void> {
  let counts: StatusCounts = { total: 0, ready: 0, inProgress: 0, completed: 0, blocked: 0 };
  let daemonSnapshot: DaemonStatusSnapshot | null = null;
  try {
    daemonSnapshot = await fetchDaemonStatusSnapshot(projectPath);
    counts = daemonSnapshot?.counts ?? await fetchTaskCounts(projectPath);
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

  if (daemonSnapshot) {
    if (daemonSnapshot.failed > 0) console.log(`  Failed:      ${chalk.red(daemonSnapshot.failed)} ${chalk.dim("(last 24h)")}`);
    if (daemonSnapshot.stuck > 0) console.log(`  Stuck:       ${chalk.red(daemonSnapshot.stuck)} ${chalk.dim("(last 24h)")}`);
    console.log(`  Success Rate (24h): ${chalk.dim("--")} ${chalk.dim("(daemon metrics pending)")}`);
  } else {
    const store = ForemanStore.forProject(projectPath);
    const project = store.getProjectByPath(projectPath);
    if (project) {
      const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
      const failedCount = store.getRunsByStatusSince("failed", since, project.id).length;
      const stuckCount = store.getRunsByStatusSince("stuck", since, project.id).length;
      if (failedCount > 0) console.log(`  Failed:      ${chalk.red(failedCount)} ${chalk.dim("(last 24h)")}`);
      if (stuckCount > 0) console.log(`  Stuck:       ${chalk.red(stuckCount)} ${chalk.dim("(last 24h)")}`);
      const sr = store.getSuccessRate(project.id);
      console.log(`  Success Rate (24h): ${formatSuccessRate(sr.rate)}${sr.rate === null ? chalk.dim(" (need 3+ runs)") : ""}`);
    }
    store.close();
  }

  console.log();
  console.log(chalk.bold("Active Agents"));

  if (daemonSnapshot) {
    const activeRuns = daemonSnapshot.activeRuns;
    if (activeRuns.length === 0) {
      console.log(chalk.dim("  (no agents running)"));
    } else {
      for (let i = 0; i < activeRuns.length; i++) {
        console.log(renderDaemonRunCard(activeRuns[i]!));
        if (i < activeRuns.length - 1) console.log();
      }
    }
  } else {
    const store = ForemanStore.forProject(projectPath);
    const project = store.getProjectByPath(projectPath);
    if (project) {
      const activeRuns = store.getActiveRuns(project.id);
      if (activeRuns.length === 0) {
        console.log(chalk.dim("  (no agents running)"));
      } else {
        for (let i = 0; i < activeRuns.length; i++) {
          const run = activeRuns[i];
          const progress = store.getRunProgress(run.id);
          const allRuns = store.getRunsForSeed(run.seed_id, project.id);
          const attemptNumber = allRuns.length > 1 ? allRuns.length : undefined;
          const previousRun = allRuns.length > 1 ? allRuns[1] : null;
          const previousStatus = previousRun?.status;
          console.log(renderAgentCard(run, progress, true, undefined, attemptNumber, previousStatus));
          if (run.status === "running") {
            const lastActivity = await getLastPiActivity(run.id);
            if (lastActivity) {
              console.log(`  ${chalk.dim("Last tool  ")} ${chalk.dim(lastActivity)}`);
            }
          }
          if (i < activeRuns.length - 1) console.log();
        }
      }

      const metrics = store.getMetrics(project.id);
      if (metrics.totalCost > 0) {
        console.log();
        console.log(chalk.bold("Costs"));
        console.log(`  Total: ${chalk.yellow(`$${metrics.totalCost.toFixed(2)}`)}`);
        console.log(`  Tokens: ${chalk.dim(`${(metrics.totalTokens / 1000).toFixed(1)}k`)}`);
      }
    } else {
      console.log(chalk.dim("  (project not registered — run 'foreman init')"));
    }
    store.close();
  }
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
    // Require --project or --all in multi-project mode
    if (!opts.all) {
      await requireProjectOrAllInMultiMode(opts.project, opts.all ?? false);
    }

    if (opts.all) {
      const projects = await listRegisteredProjects();

      if (projects.length === 0) {
        console.log(chalk.yellow("No registered projects found. Run 'foreman project add' to register projects."));
        return;
      }

      const aggregated: StatusCounts = { total: 0, ready: 0, inProgress: 0, completed: 0, blocked: 0 };
      let totalFailed = 0;
      let totalStuck = 0;
      let totalActiveAgents = 0;

      for (const proj of projects) {
        try {
          const client = createTrpcClient();
          const stats = await client.projects.stats({ projectId: proj.id }) as ProjectStats;
          const needsHuman = await client.projects.listNeedsHuman({ projectId: proj.id }) as Array<{ status: string }>;
          aggregated.total += stats.tasks.total;
          aggregated.ready += stats.tasks.ready;
          aggregated.inProgress += stats.tasks.inProgress;
          aggregated.completed += stats.tasks.merged + stats.tasks.closed;
          aggregated.blocked += stats.tasks.backlog;
          totalFailed += needsHuman.filter((task) => task.status === "failed" || task.status === "conflict").length;
          totalStuck += needsHuman.filter((task) => task.status === "stuck").length;
          totalActiveAgents += stats.runs.active;
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
      console.log();
      console.log(chalk.dim(`Projects: ${projects.map((p) => p.name).join(", ")}`));
      return;
    }

    const projectPath = await resolveRepoRootProjectPath(opts);
    if (opts.json) {
      // JSON output path — gather data and serialize
      try {
        const daemon = await fetchDaemonStatusSnapshot(projectPath);

        let counts: StatusCounts = { total: 0, ready: 0, inProgress: 0, completed: 0, blocked: 0 };
        let failed = 0;
        let stuck = 0;
        let activeRuns: unknown[] = [];
        let successRateData: { rate: number | null; merged: number; failed: number } = { rate: null, merged: 0, failed: 0 };
        let metrics: Metrics = { totalCost: 0, totalTokens: 0, tasksByStatus: {}, costByRuntime: [] };

        if (daemon) {
          counts = daemon.counts;
          failed = daemon.failed;
          stuck = daemon.stuck;
          activeRuns = daemon.activeRuns;
        } else {
          counts = await fetchTaskCounts(projectPath);
          const store = ForemanStore.forProject(projectPath);
          const project = store.getProjectByPath(projectPath);
          if (project) {
            const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
            failed = store.getRunsByStatusSince("failed", since, project.id).length;
            stuck = store.getRunsByStatusSince("stuck", since, project.id).length;
            const runs = store.getActiveRuns(project.id);
            activeRuns = runs.map((run) => ({ ...run, progress: store.getRunProgress(run.id) }));
            successRateData = store.getSuccessRate(project.id);
            metrics = store.getMetrics(project.id);
          }
          store.close();
        }

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
            active: activeRuns,
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
          let counts: StatusCounts = { total: 0, ready: 0, inProgress: 0, completed: 0, blocked: 0 };
          try {
            counts = await fetchStatusCounts(projectPath);
          } catch { /* br not available — show zero counts */ }

          const daemonDashboard = await fetchDaemonDashboardState(projectPath);
          const dashState = daemonDashboard ?? (() => {
            const store = ForemanStore.forProject(projectPath);
            try {
              return pollDashboard(store, undefined, 8);
            } finally {
              store.close();
            }
          })();

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
