import { Command } from "commander";
import chalk from "chalk";

import { ForemanStore, type Run } from "../../lib/store.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";

// ── Types ─────────────────────────────────────────────────────────────

export interface StopOpts {
  list?: boolean;
  force?: boolean;
  dryRun?: boolean;
}

export interface StopResult {
  signalled: boolean;
  wouldSignal: boolean;
  markedStuck: boolean;
  wouldMarkStuck: boolean;
  warnings: string[];
  errors: string[];
}

// ── Core action (exported for testing) ───────────────────────────────

/**
 * Core stop logic extracted for testability.
 * Returns the exit code (0 = success, 1 = error).
 */
export async function stopAction(
  id: string | undefined,
  opts: StopOpts,
  store: ForemanStore,
  projectPath: string,
): Promise<number> {
  const dryRun = opts.dryRun ?? false;
  const force = opts.force ?? false;

  // ── --list ─────────────────────────────────────────────────────────
  if (opts.list) {
    const listProject = store.getProjectByPath(projectPath);
    if (!listProject) {
      console.error(chalk.red("No project registered for this path. Run 'foreman init' first."));
      return 1;
    }
    listActiveRuns(store, projectPath);
    return 0;
  }

  const project = store.getProjectByPath(projectPath);
  if (!project) {
    console.error(chalk.red("No project registered for this path. Run 'foreman init' first."));
    return 1;
  }

  if (dryRun) {
    console.log(chalk.yellow("(dry run — no changes will be made)\n"));
  }

  // ── Single run by ID or seed ID ────────────────────────────────────
  if (id) {
    const run = findRun(store, id, project.id);
    if (!run) {
      console.error(chalk.red(`No run found for "${id}". Use 'foreman stop --list' to see active runs.`));
      return 1;
    }

    const result = await stopRun(run, store, { dryRun, force });
    return shouldFailStop(result, dryRun) ? 1 : 0;
  }

  // ── Stop all active runs ───────────────────────────────────────────
  const activeRuns = store.getActiveRuns(project.id);

  if (activeRuns.length === 0) {
    console.log(chalk.yellow("No active runs to stop."));
    return 0;
  }

  console.log(chalk.bold(`${dryRun ? "Reviewing" : "Stopping"} ${activeRuns.length} active run(s):\n`));

  let signalledCount = 0;
  let wouldSignalCount = 0;
  let markedStuckCount = 0;
  let wouldMarkStuckCount = 0;
  let degradedRuns = 0;
  let failedRuns = 0;

  for (const run of activeRuns) {
    const result = await stopRun(run, store, { dryRun, force });
    if (result.signalled) signalledCount += 1;
    if (result.wouldSignal) wouldSignalCount += 1;
    if (result.markedStuck) markedStuckCount += 1;
    if (result.wouldMarkStuck) wouldMarkStuckCount += 1;
    if (result.warnings.length > 0) degradedRuns += 1;
    if (result.errors.length > 0) failedRuns += 1;
  }

  console.log(chalk.bold("\nSummary:"));
  if (dryRun) {
    console.log(`  Would signal processes: ${wouldSignalCount}`);
    console.log(`  Would mark runs as stuck: ${wouldMarkStuckCount}`);
  } else {
    console.log(`  Processes signalled: ${signalledCount}`);
    console.log(`  Runs marked stuck: ${markedStuckCount}`);
  }

  if (degradedRuns > 0) {
    console.warn(chalk.yellow(`  ${dryRun ? "Would leave" : "Left"} ${degradedRuns} run(s) incompletely stopped (no live pid was signalled).`));
  }

  if (failedRuns > 0) {
    console.error(chalk.red(`  ${failedRuns} run(s) failed to stop cleanly.`));
  }

  if (!dryRun && markedStuckCount > 0) {
    console.log(chalk.dim("\nRuns marked 'stuck' can be resumed with: foreman run"));
  }

  return dryRun ? 0 : (degradedRuns > 0 || failedRuns > 0 ? 1 : 0);
}

// ── Internal helpers ──────────────────────────────────────────────────

/**
 * Stop a single run gracefully (or forcefully with --force).
 * Does NOT remove worktrees, branches, or reset seeds.
 * Marks runs as "stuck" so they can be resumed.
 */
async function stopRun(
  run: Run,
  store: ForemanStore,
  opts: { dryRun: boolean; force: boolean },
): Promise<StopResult> {
  const { dryRun, force } = opts;
  const errors: string[] = [];
  const warnings: string[] = [];
  let processKilled = false;
  let markedStuck = false;

  console.log(
    `  ${chalk.cyan(run.seed_id)} ${chalk.dim(`[${run.id}]`)} status=${run.status}`,
  );

  const pid = extractPid(run.session_key);
  const pidAlive = pid !== null ? isAlive(pid) : false;
  const signal = force ? "SIGKILL" : "SIGTERM";
  const isActiveRun = run.status === "running" || run.status === "pending";
  const wouldSignal = pid !== null && pidAlive;

  if (wouldSignal) {
    if (dryRun) {
      console.log(`    ${chalk.yellow("would send")} ${signal} to pid ${pid}`);
    } else {
      try {
        console.log(`    ${chalk.yellow("send")} ${signal} to pid ${pid}`);
        process.kill(pid, signal);
        processKilled = true;
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        errors.push(`Failed to send ${signal} to pid ${pid}: ${msg}`);
        console.error(`    ${chalk.red("error")} sending ${signal} to pid ${pid}: ${msg}`);
      }
    }
  } else if (pid !== null) {
    const warning = `pid ${pid} is not running; ${dryRun ? "would mark" : "marking"} run as stuck without sending ${signal}`;
    warnings.push(warning);
    console.warn(`    ${chalk.yellow("warn")} ${warning}`);
  } else {
    const warning = `no pid found; ${dryRun ? "would mark" : "marking"} run as stuck without sending ${signal}`;
    warnings.push(warning);
    console.warn(`    ${chalk.yellow("warn")} ${warning}`);
  }

  const wouldMarkStuck = isActiveRun && (wouldSignal || pid === null || !pidAlive);
  if (isActiveRun && wouldMarkStuck) {
    if (dryRun) {
      console.log(`    ${chalk.yellow("would mark")} run as stuck`);
    } else if (processKilled || pid === null || !pidAlive) {
      console.log(`    ${chalk.yellow("mark")} run as stuck`);
      store.updateRun(run.id, {
        status: "stuck",
        completed_at: new Date().toISOString(),
      });
      store.logEvent(run.project_id, "stuck", { reason: "foreman stop" }, run.id);
      markedStuck = true;
    }
  }

  console.log();
  return {
    signalled: processKilled,
    wouldSignal,
    markedStuck,
    wouldMarkStuck,
    warnings,
    errors,
  };
}

/**
 * List active runs with full details.
 */
export function listActiveRuns(store: ForemanStore, projectPath: string): void {
  const project = store.getProjectByPath(projectPath);
  if (!project) {
    console.error(chalk.red("No project registered for this directory. Run 'foreman init' first."));
    return;
  }

  const activeRuns = store.getActiveRuns(project.id);

  if (activeRuns.length === 0) {
    console.log("No active runs found.");
    return;
  }

  console.log("Active runs:\n");
  console.log(
    "  " +
    "SEED".padEnd(22) +
    "STATUS".padEnd(12) +
    "AGENT".padEnd(24) +
    "ELAPSED".padEnd(12) +
    "PID",
  );
  console.log("  " + "\u2500".repeat(84));

  for (const run of activeRuns) {
    const pid = extractPid(run.session_key);
    const pidStr = pid ? String(pid) : "(none)";
    const elapsed = formatElapsed(run.started_at);

    console.log(
      "  " +
      run.seed_id.padEnd(22) +
      run.status.padEnd(12) +
      run.agent_type.padEnd(24) +
      elapsed.padEnd(12) +
      pidStr,
    );
  }
  console.log();
}

function shouldFailStop(result: StopResult, dryRun: boolean): boolean {
  if (dryRun) {
    return false;
  }

  return result.warnings.length > 0 || result.errors.length > 0;
}

function findRun(store: ForemanStore, id: string, projectId: string): Run | null {
  // Try by run ID first — must belong to this project to avoid cross-project leakage
  const byRunId = store.getRun(id);
  if (byRunId && byRunId.project_id === projectId) return byRunId;

  // Then by seed ID (most recent run for this project)
  const bySeedId = store.getRunsForSeed(id, projectId);
  if (bySeedId.length > 0) return bySeedId[0];

  return null;
}

function extractPid(sessionKey: string | null): number | null {
  if (!sessionKey) return null;
  const m = sessionKey.match(/pid-(\d+)/);
  return m ? parseInt(m[1], 10) : null;
}

function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function formatElapsed(startedAt: string | null): string {
  if (!startedAt) return "-";
  const start = new Date(startedAt).getTime();
  const now = Date.now();
  const diffMs = now - start;
  if (diffMs < 0) return "-";

  const totalSeconds = Math.floor(diffMs / 1000);
  if (totalSeconds < 60) return `${totalSeconds}s`;

  const totalMinutes = Math.floor(diffMs / 60000);
  if (totalMinutes < 60) {
    return `${totalMinutes}m`;
  }
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  return `${hours}h ${minutes}m`;
}

// ── CLI Command ─────────────────────────────────────────────────────────

export const stopCommand = new Command("stop")
  .description("Gracefully stop running foreman agents without destroying infrastructure")
  .argument("[id]", "Run ID or bead ID to stop (omit to stop all active runs)")
  .option("--list", "List all active runs")
  .option("--force", "Force kill with SIGKILL instead of SIGTERM")
  .option("--dry-run", "Show what would be stopped without doing it")
  .action(async (id: string | undefined, opts: StopOpts) => {
    // Resolve project path first so the store is opened at the project-local location.
    let projectPath: string;
    let isGitRepo = true;
    try {
      const vcs = await VcsBackendFactory.create({ backend: "auto" }, process.cwd());
      projectPath = await vcs.getRepoRoot(process.cwd());
    } catch {
      // Fall back to cwd for --list (shows runs even outside a git repo), but
      // for all other operations we require a git repo below.
      projectPath = process.cwd();
      isGitRepo = false;
    }

    const store = ForemanStore.forProject(projectPath);
    try {
      if (!isGitRepo && !opts.list) {
        console.error(chalk.red("Not in a git repository. Run from within a foreman project."));
        process.exit(1);
      }

      const exitCode = await stopAction(id, opts, store, projectPath);
      process.exit(exitCode);
    } finally {
      store.close();
    }
  });
