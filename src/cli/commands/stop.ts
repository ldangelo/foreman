import { Command } from "commander";
import chalk from "chalk";

import { ForemanStore, type Run } from "../../lib/store.js";
import { PostgresStore } from "../../lib/postgres-store.js";
import { ensureCliPostgresPool, listRegisteredProjects, resolveRepoRootProjectPath } from "./project-task-support.js";

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

interface StopStore {
  getProjectByPath(path: string): Promise<{ id: string; path: string } | null>;
  getActiveRuns(projectId: string): Promise<Run[]>;
  getRun(id: string): Promise<Run | null>;
  getRunsForSeed(seedId: string, projectId: string): Promise<Run[]>;
  updateRun(runId: string, updates: Partial<Pick<Run, "status" | "completed_at">>): Promise<void>;
  logEvent(projectId: string, eventType: "stuck", data: Record<string, unknown>, runId?: string): Promise<void>;
}

export function wrapLocalStopStore(store: ForemanStore): StopStore {
  return {
    getProjectByPath: async (path) => store.getProjectByPath(path),
    getActiveRuns: async (projectId) => store.getActiveRuns(projectId),
    getRun: async (id) => store.getRun(id),
    getRunsForSeed: async (seedId, projectId) => store.getRunsForSeed(seedId, projectId),
    updateRun: async (runId, updates) => store.updateRun(runId, updates),
    logEvent: async (projectId, eventType, data, runId) => store.logEvent(projectId, eventType, data, runId),
  };
}

// ── Core action (exported for testing) ───────────────────────────────

/**
 * Core stop logic extracted for testability.
 * Returns the exit code (0 = success, 1 = error).
 */
export async function stopAction(
  id: string | undefined,
  opts: StopOpts,
  store: StopStore,
  projectPath: string,
): Promise<number> {
  const dryRun = opts.dryRun ?? false;
  const force = opts.force ?? false;

  // ── --list ─────────────────────────────────────────────────────────
  if (opts.list) {
    const listProject = await store.getProjectByPath(projectPath);
    if (!listProject) {
      console.error(chalk.red("No project registered for this path. Run 'foreman init' first."));
      return 1;
    }
    await listActiveRuns(store, projectPath);
    return 0;
  }

  const project = await store.getProjectByPath(projectPath);
  if (!project) {
    console.error(chalk.red("No project registered for this path. Run 'foreman init' first."));
    return 1;
  }

  if (dryRun) {
    console.log(chalk.yellow("(dry run — no changes will be made)\n"));
  }

  // ── Single run by ID or seed ID ────────────────────────────────────
  if (id) {
    const run = await findRun(store, id, project.id);
    if (!run) {
      console.error(chalk.red(`No run found for "${id}". Use 'foreman stop --list' to see active runs.`));
      return 1;
    }

    const result = await stopRun(run, store, { dryRun, force });
    printStopResult(run, result);
    return result.errors.length > 0 ? 1 : 0;
  }

  // ── Stop all active runs ───────────────────────────────────────────
  const activeRuns = await store.getActiveRuns(project.id);

  if (activeRuns.length === 0) {
    console.log(chalk.yellow("No active runs to stop."));
    return 0;
  }

  console.log(chalk.bold(`Stopping ${activeRuns.length} active run(s):\n`));

  const stoppedRunIds = new Set<string>();
  const allErrors: string[] = [];

  for (const run of activeRuns) {
    const result = await stopRun(run, store, { dryRun, force });
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
  store: StopStore,
  opts: { dryRun: boolean; force: boolean },
): Promise<StopResult> {
  const { dryRun, force } = opts;
  const errors: string[] = [];
  let processKilled = false;

  console.log(
    `  ${chalk.cyan(run.seed_id)} ${chalk.dim(`[${run.id}]`)} status=${run.status}`,
  );

  const pid = getWorkerPid(run);
  const signal = force ? "SIGKILL" : "SIGTERM";

  // Kill process by PID if available
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
  } else if (!pid) {
    // No pid found — warn but still mark stuck so foreman run won't re-queue as running
    console.log(
      `    ${chalk.yellow("warn")} no pid found — marking stuck anyway`,
    );
  }

  // 3. Mark run as stuck (so foreman run --resume can pick it up)
  if (run.status === "running" || run.status === "pending") {
    console.log(`    ${chalk.yellow("mark")} run as stuck`);
    if (!dryRun) {
        await store.updateRun(run.id, {
          status: "stuck",
          completed_at: new Date().toISOString(),
        });
        await store.logEvent(run.project_id, "stuck", { reason: "foreman stop" }, run.id);
      }
    }

  console.log();
  return { stopped: dryRun ? 0 : (processKilled ? 1 : 0), errors, skipped: 0 };
}

/**
 * List active runs with full details.
 */
export async function listActiveRuns(store: StopStore, projectPath: string): Promise<void> {
  const project = await store.getProjectByPath(projectPath);
  if (!project) {
    console.error(chalk.red("No project registered for this directory. Run 'foreman init' first."));
    return;
  }

  const activeRuns = await store.getActiveRuns(project.id);

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

export async function stopCommandAction(id: string | undefined, opts: StopOpts): Promise<number> {
  let projectPath: string;
  let isGitRepo = true;
  try {
    projectPath = await resolveRepoRootProjectPath({});
  } catch {
    projectPath = process.cwd();
    isGitRepo = false;
  }

  const registered = (await listRegisteredProjects()).find((project) => project.path === projectPath);
  const localStore = ForemanStore.forProject(projectPath);
  if (registered) {
    ensureCliPostgresPool(projectPath);
  }
  const store: StopStore = registered ? PostgresStore.forProject(registered.id) : wrapLocalStopStore(localStore);

  const closeStores = () => {
    localStore.close();
    const maybeCloseStore = store as { close?: () => void };
    if (typeof maybeCloseStore.close === "function") {
      maybeCloseStore.close();
    }
  };

  if (opts.list) {
    await listActiveRuns(store, projectPath);
    closeStores();
    return 0;
  }

  if (!isGitRepo) {
    console.error(chalk.red("Not in a git repository. Run from within a foreman project."));
    closeStores();
    return 1;
  }

  const exitCode = await stopAction(id, opts, store, projectPath);
  closeStores();
  return exitCode;
}

function printStopResult(run: Run, result: StopResult): void {
  if (result.errors.length === 0 && result.skipped === 0) {
    // Success output already printed by stopRun
  } else if (result.skipped > 0) {
    console.log(`  ${chalk.dim(run.seed_id)} — no active session to stop`);
  }
}

async function findRun(store: StopStore, id: string, projectId: string): Promise<Run | null> {
  // Try by run ID first — must belong to this project to avoid cross-project leakage
  const byRunId = await store.getRun(id);
  if (byRunId && byRunId.project_id === projectId) return byRunId;

  // Then by seed ID (most recent run for this project)
  const bySeedId = await store.getRunsForSeed(id, projectId);
  if (bySeedId.length > 0) return bySeedId[0];

  return null;
}

function getWorkerPid(run: Run): number | null {
  return extractPid(run.session_key);
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
    process.exit(await stopCommandAction(id, opts));
  });
