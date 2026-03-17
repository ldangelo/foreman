import { Command } from "commander";
import chalk from "chalk";

import { ForemanStore, type Run } from "../../lib/store.js";
import { getRepoRoot } from "../../lib/git.js";
import { TmuxClient } from "../../lib/tmux.js";

// ── Types ─────────────────────────────────────────────────────────────

export interface StopOpts {
  list?: boolean;
  force?: boolean;
  dryRun?: boolean;
}

export interface StopResult {
  stopped: number;
  errors: string[];
  skipped: number;
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
  const tmux = new TmuxClient();
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

    const result = await stopRun(run, store, tmux, { dryRun, force });
    printStopResult(run, result);
    return result.errors.length > 0 ? 1 : 0;
  }

  // ── Stop all active runs ───────────────────────────────────────────
  const activeRuns = store.getActiveRuns(project.id);

  if (activeRuns.length === 0) {
    console.log(chalk.yellow("No active runs to stop."));
    return 0;
  }

  console.log(chalk.bold(`Stopping ${activeRuns.length} active run(s):\n`));

  const stoppedRunIds = new Set<string>();
  const allErrors: string[] = [];

  for (const run of activeRuns) {
    const result = await stopRun(run, store, tmux, { dryRun, force });
    printStopResult(run, result);
    if (result.stopped > 0) stoppedRunIds.add(run.id);
    allErrors.push(...result.errors);
  }

  console.log(chalk.bold("\nSummary:"));
  if (dryRun) {
    console.log(chalk.yellow(`  Would stop ${activeRuns.length} run(s)`));
  } else {
    console.log(`  Runs stopped: ${stoppedRunIds.size}`);
  }

  if (allErrors.length > 0) {
    console.log(chalk.red(`\n  Errors (${allErrors.length}):`));
    for (const err of allErrors) {
      console.log(chalk.red(`    ${err}`));
    }
  }

  if (!dryRun) {
    console.log(chalk.dim("\nRuns are marked 'stuck'. Resume with: foreman run"));
  }

  return allErrors.length > 0 ? 1 : 0;
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
  tmux: TmuxClient,
  opts: { dryRun: boolean; force: boolean },
): Promise<StopResult> {
  const { dryRun, force } = opts;
  const errors: string[] = [];
  let processKilled = false;

  console.log(
    `  ${chalk.cyan(run.seed_id)} ${chalk.dim(`[${run.id}]`)} status=${run.status}`,
  );

  const pid = extractPid(run.session_key);
  const signal = force ? "SIGKILL" : "SIGTERM";

  // 1. Kill tmux session if available
  if (run.tmux_session) {
    console.log(`    ${chalk.yellow("kill")} tmux session ${run.tmux_session}`);
    if (!dryRun) {
      try {
        const killed = await tmux.killSession(run.tmux_session);
        if (killed) {
          processKilled = true;
          console.log(`    ${chalk.green("ok")} killed tmux session ${run.tmux_session}`);
        } else {
          console.log(`    ${chalk.dim("skip")} tmux session ${run.tmux_session} not found`);
        }
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        errors.push(`Failed to kill tmux session ${run.tmux_session}: ${msg}`);
        console.log(`    ${chalk.red("error")} killing tmux session: ${msg}`);
      }
    }
  }

  // 2. Kill process by PID if available (check after tmux kill; SIGHUP may have already reaped it)
  if (pid && isAlive(pid)) {
    console.log(`    ${chalk.yellow("send")} ${signal} to pid ${pid}`);
    if (!dryRun) {
      try {
        process.kill(pid, signal);
        processKilled = true;
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        errors.push(`Failed to send ${signal} to pid ${pid}: ${msg}`);
        console.log(`    ${chalk.red("error")} sending ${signal} to pid ${pid}: ${msg}`);
      }
    }
  } else if (!run.tmux_session && !pid) {
    // No session handle found — warn but still mark stuck so foreman run won't re-queue as running
    console.log(
      `    ${chalk.yellow("warn")} no tmux session or pid found — marking stuck anyway`,
    );
  }

  // 3. Mark run as stuck (so foreman run --resume can pick it up)
  if (run.status === "running" || run.status === "pending") {
    console.log(`    ${chalk.yellow("mark")} run as stuck`);
    if (!dryRun) {
      store.updateRun(run.id, {
        status: "stuck",
        completed_at: new Date().toISOString(),
      });
      store.logEvent(run.project_id, "stuck", { reason: "foreman stop" }, run.id);
    }
  }

  console.log();
  return { stopped: dryRun ? 0 : (processKilled ? 1 : 0), errors, skipped: 0 };
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
    "TMUX".padEnd(24) +
    "PID",
  );
  console.log("  " + "\u2500".repeat(110));

  for (const run of activeRuns) {
    const pid = extractPid(run.session_key);
    const pidStr = pid ? String(pid) : "(none)";
    const tmuxName = run.tmux_session ?? "(none)";
    const elapsed = formatElapsed(run.started_at);

    console.log(
      "  " +
      run.seed_id.padEnd(22) +
      run.status.padEnd(12) +
      run.agent_type.padEnd(24) +
      elapsed.padEnd(12) +
      tmuxName.padEnd(24) +
      pidStr,
    );
  }
  console.log();
}

function printStopResult(run: Run, result: StopResult): void {
  if (result.errors.length === 0 && result.skipped === 0) {
    // Success output already printed by stopRun
  } else if (result.skipped > 0) {
    console.log(`  ${chalk.dim(run.seed_id)} — no active session to stop`);
  }
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
  .argument("[id]", "Run ID or seed ID to stop (omit to stop all active runs)")
  .option("--list", "List all active runs")
  .option("--force", "Force kill with SIGKILL instead of SIGTERM")
  .option("--dry-run", "Show what would be stopped without doing it")
  .action(async (id: string | undefined, opts: StopOpts) => {
    // Resolve project path first so the store is opened at the project-local location.
    let projectPath: string;
    let isGitRepo = true;
    try {
      projectPath = await getRepoRoot(process.cwd());
    } catch {
      // Fall back to cwd for --list (shows runs even outside a git repo), but
      // for all other operations we require a git repo below.
      projectPath = process.cwd();
      isGitRepo = false;
    }

    const store = ForemanStore.forProject(projectPath);

    if (opts.list) {
      listActiveRuns(store, projectPath);
      store.close();
      return;
    }

    if (!isGitRepo) {
      console.error(chalk.red("Not in a git repository. Run from within a foreman project."));
      store.close();
      process.exit(1);
    }

    const exitCode = await stopAction(id, opts, store, projectPath);
    store.close();
    process.exit(exitCode);
  });
