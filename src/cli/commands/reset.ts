import { Command } from "commander";
import chalk from "chalk";

import { BeadsRustClient } from "../../lib/beads-rust.js";
import { ForemanStore } from "../../lib/store.js";
import type { Run } from "../../lib/store.js";
import { getRepoRoot } from "../../lib/git.js";
import { removeWorktree, deleteBranch, listWorktrees } from "../../lib/git.js";
import { TmuxClient } from "../../lib/tmux.js";
import type { UpdateOptions } from "../../lib/task-client.js";
import { PIPELINE_LIMITS } from "../../lib/config.js";

/**
 * Minimal interface capturing the subset of task-client methods used by
 * detectAndFixMismatches. BeadsRustClient satisfies this interface
 * (note: show() is not on ITaskClient, hence this local type).
 */
export interface IShowUpdateClient {
  show(id: string): Promise<{ status: string }>;
  update(id: string, opts: UpdateOptions): Promise<void>;
}

// ── State mismatch detection ─────────────────────────────────────────────

export interface StateMismatch {
  seedId: string;
  runId: string;
  runStatus: string;
  actualSeedStatus: string;
  expectedSeedStatus: string;
}

export interface MismatchResult {
  mismatches: StateMismatch[];
  fixed: number;
  errors: string[];
}

/**
 * Map a run status to the expected seed status.
 * This defines the correct seed state given a run's terminal state.
 */
export function mapRunStatusToSeedStatus(runStatus: string): string {
  switch (runStatus) {
    case "pending":
    case "running":
      return "in_progress";
    case "completed":
      return "closed";
    case "failed":
    case "stuck":
      return "open";
    case "merged":
    case "pr-created":
      return "closed";
    case "conflict":
    case "test-failed":
      return "open";
    default:
      return "open";
  }
}

/**
 * Detect and fix seed/run state mismatches.
 *
 * Checks all terminal runs (completed, merged, etc.) for seeds that are still
 * stuck in "in_progress". Seeds that are already included in the `resetSeedIds`
 * set are skipped — those will be handled by the main reset loop.
 *
 * Seeds with active (pending/running) runs are skipped to avoid the race
 * condition where auto-dispatch has just marked a seed as in_progress but the
 * reset sees the old terminal run and incorrectly overwrites the status.
 *
 * For each mismatch found, the seed status is updated to the expected value
 * (unless dryRun is true).
 */
export async function detectAndFixMismatches(
  store: Pick<ForemanStore, "getRunsByStatus" | "getActiveRuns">,
  seeds: IShowUpdateClient,
  projectId: string,
  resetSeedIds: ReadonlySet<string>,
  opts?: { dryRun?: boolean },
): Promise<MismatchResult> {
  const dryRun = opts?.dryRun ?? false;

  // Check terminal run statuses not already handled by the reset loop
  const checkStatuses = ["completed", "merged", "pr-created", "conflict", "test-failed"] as const;
  const terminalRuns = checkStatuses.flatMap((s) => store.getRunsByStatus(s, projectId));

  // Short-circuit: nothing to check, skip the extra DB read for active runs.
  if (terminalRuns.length === 0) return { mismatches: [], fixed: 0, errors: [] };

  // Build a set of seed IDs that have active (pending/running) runs.
  // We skip those to avoid clobbering seeds that were just dispatched.
  const activeRuns = store.getActiveRuns(projectId);
  const activeSeedIds = new Set(activeRuns.map((r) => r.seed_id));

  // Deduplicate by seed_id: keep the most recently created run per seed
  const latestBySeed = new Map<string, Run>();
  for (const run of terminalRuns) {
    // Skip seeds already being reset by the main loop
    if (resetSeedIds.has(run.seed_id)) continue;

    // Skip seeds that have an active run — they are being dispatched right now
    if (activeSeedIds.has(run.seed_id)) continue;

    const existing = latestBySeed.get(run.seed_id);
    if (!existing || run.created_at > existing.created_at) {
      latestBySeed.set(run.seed_id, run);
    }
  }

  const mismatches: StateMismatch[] = [];
  const errors: string[] = [];
  let fixed = 0;

  for (const run of latestBySeed.values()) {
    const expectedSeedStatus = mapRunStatusToSeedStatus(run.status);
    try {
      const seedDetail = await seeds.show(run.seed_id);

      if (seedDetail.status !== expectedSeedStatus) {
        mismatches.push({
          seedId: run.seed_id,
          runId: run.id,
          runStatus: run.status,
          actualSeedStatus: seedDetail.status,
          expectedSeedStatus,
        });

        if (!dryRun) {
          try {
            await seeds.update(run.seed_id, { status: expectedSeedStatus });
            fixed++;
          } catch (err: unknown) {
            const msg = err instanceof Error ? err.message : String(err);
            errors.push(`Failed to fix mismatch for seed ${run.seed_id}: ${msg}`);
          }
        }
      }
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      if (!msg.includes("not found") && !msg.includes("Issue not found")) {
        errors.push(`Could not check seed ${run.seed_id}: ${msg}`);
      }
      // Seed not found — skip silently
    }
  }

  return { mismatches, fixed, errors };
}

// ── Stuck-run detection ───────────────────────────────────────────────────

export interface StuckDetectionResult {
  /** Runs newly identified as stuck during detection. */
  stuck: Run[];
  /** Any errors that occurred during detection (non-fatal). */
  errors: string[];
}

/**
 * Detect stuck active runs by:
 *  1. Tmux liveness check — if a tmux session is dead, the run is stuck.
 *  2. Timeout check — if elapsed time > stuckTimeoutMinutes, the run is stuck.
 *
 * Updates the store for each newly-detected stuck run and returns the list.
 * Runs that are already in "stuck" status are not re-detected here (they will
 * be picked up by the main reset loop).
 */
export async function detectStuckRuns(
  store: Pick<ForemanStore, "getActiveRuns" | "updateRun" | "logEvent">,
  projectId: string,
  opts?: {
    stuckTimeoutMinutes?: number;
    tmux?: Pick<TmuxClient, "hasSession">;
    dryRun?: boolean;
  },
): Promise<StuckDetectionResult> {
  const stuckTimeout = opts?.stuckTimeoutMinutes ?? PIPELINE_LIMITS.stuckDetectionMinutes;
  const dryRun = opts?.dryRun ?? false;
  const tmux = opts?.tmux;

  // Only look at "running" (not pending/failed/stuck — those are handled elsewhere)
  const activeRuns = store.getActiveRuns(projectId).filter((r) => r.status === "running");

  const stuck: Run[] = [];
  const errors: string[] = [];
  const now = Date.now();

  for (const run of activeRuns) {
    try {
      // 1. Tmux liveness check (runs BEFORE seed-status check, matching Monitor priority)
      if (tmux && run.tmux_session) {
        const tmuxAlive = await tmux.hasSession(run.tmux_session);
        if (!tmuxAlive) {
          if (!dryRun) {
            store.updateRun(run.id, { status: "stuck" });
            store.logEvent(
              run.project_id,
              "stuck",
              {
                seedId: run.seed_id,
                detectedBy: "tmux-liveness",
                tmuxSession: run.tmux_session,
              },
              run.id,
            );
          }
          stuck.push({ ...run, status: "stuck" });
          continue;
        }
      }

      // 2. Timeout check — if elapsed time exceeds stuckTimeout
      if (run.started_at) {
        const startedAt = new Date(run.started_at).getTime();
        const elapsedMinutes = (now - startedAt) / (1000 * 60);

        if (elapsedMinutes > stuckTimeout) {
          if (!dryRun) {
            store.updateRun(run.id, { status: "stuck" });
            store.logEvent(
              run.project_id,
              "stuck",
              { seedId: run.seed_id, elapsedMinutes: Math.round(elapsedMinutes), detectedBy: "timeout" },
              run.id,
            );
          }
          stuck.push({ ...run, status: "stuck" });
          continue;
        }
      }
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      errors.push(`Could not check run ${run.seed_id}: ${msg}`);
    }
  }

  return { stuck, errors };
}

export const resetCommand = new Command("reset")
  .description("Reset failed/stuck runs: kill agents, remove worktrees, reset beads to open")
  .option("--all", "Reset ALL active runs, not just failed/stuck ones")
  .option("--detect-stuck", "Run stuck detection first, adding newly-detected stuck runs to the reset list")
  .option(
    "--timeout <minutes>",
    "Stuck detection timeout in minutes (used with --detect-stuck)",
    String(PIPELINE_LIMITS.stuckDetectionMinutes),
  )
  .option("--dry-run", "Show what would be reset without doing it")
  .action(async (opts, cmd) => {
    const dryRun = opts.dryRun as boolean | undefined;
    const all = opts.all as boolean | undefined;
    const detectStuck = opts.detectStuck as boolean | undefined;
    const timeoutMinutes = parseInt(opts.timeout as string, 10);

    if (isNaN(timeoutMinutes)) {
      console.error(
        chalk.red(`Error: --timeout must be a positive integer, got "${opts.timeout as string}"`),
      );
      process.exit(1);
    }

    // Warn if --timeout is explicitly set but --detect-stuck is not (it would be a no-op)
    if (!detectStuck && cmd.getOptionValueSource("timeout") === "user") {
      console.warn(chalk.yellow("Warning: --timeout has no effect without --detect-stuck\n"));
    }

    try {
      const projectPath = await getRepoRoot(process.cwd());
      const seeds: IShowUpdateClient = new BeadsRustClient(projectPath);
      const store = ForemanStore.forProject(projectPath);
      const project = store.getProjectByPath(projectPath);

      if (!project) {
        console.error(chalk.red("No project registered for this path. Run 'foreman init' first."));
        process.exit(1);
      }

      // Shared TmuxClient — used for both stuck detection and session cleanup
      const tmux = new TmuxClient();
      const tmuxAvailable = await tmux.isAvailable();

      // Optional: run stuck detection first, mark newly-stuck runs in the store
      if (detectStuck) {
        console.log(chalk.bold("Detecting stuck runs...\n"));
        const detectionResult = await detectStuckRuns(store, project.id, {
          stuckTimeoutMinutes: timeoutMinutes,
          tmux: tmuxAvailable ? tmux : undefined,
          dryRun,
        });

        if (detectionResult.stuck.length > 0) {
          console.log(chalk.yellow.bold(`Found ${detectionResult.stuck.length} newly stuck run(s):`));
          for (const run of detectionResult.stuck) {
            const elapsed = run.started_at
              ? Math.round((Date.now() - new Date(run.started_at).getTime()) / 60000)
              : 0;
            console.log(
              `  ${chalk.yellow(run.seed_id)} ${chalk.dim(`[${run.agent_type}]`)} ${elapsed}m`,
            );
          }
          console.log();
        } else {
          console.log(chalk.dim("  No newly stuck runs detected.\n"));
        }

        if (detectionResult.errors.length > 0) {
          for (const err of detectionResult.errors) {
            console.log(chalk.red(`  Warning: ${err}`));
          }
          console.log();
        }
      }

      // Find runs to reset
      const statuses = all
        ? ["pending", "running", "failed", "stuck"] as const
        : ["failed", "stuck"] as const;

      const runs = statuses.flatMap((s) => store.getRunsByStatus(s, project.id));

      if (dryRun) {
        console.log(chalk.yellow("(dry run — no changes will be made)\n"));
      }

      if (runs.length === 0) {
        console.log(chalk.yellow("No active runs to reset.\n"));
      } else {
        console.log(chalk.bold(`Resetting ${runs.length} run(s):\n`));
      }

      // Collect unique seed IDs to reset
      const seedIds = new Set<string>();
      let killed = 0;
      let worktreesRemoved = 0;
      let branchesDeleted = 0;
      let runsMarkedFailed = 0;
      let seedsReset = 0;
      const errors: string[] = [];

      for (const run of runs) {
        const pid = extractPid(run.session_key);
        const branchName = `foreman/${run.seed_id}`;

        console.log(`  ${chalk.cyan(run.seed_id)} ${chalk.dim(`[${run.agent_type}]`)} status=${run.status}`);

        // 1. Kill the agent process if alive
        if (pid && isAlive(pid)) {
          console.log(`    ${chalk.yellow("kill")} pid ${pid}`);
          if (!dryRun) {
            try {
              process.kill(pid, "SIGTERM");
              killed++;
            } catch (err: unknown) {
              const msg = err instanceof Error ? err.message : String(err);
              errors.push(`Failed to kill pid ${pid} for ${run.seed_id}: ${msg}`);
              console.log(`    ${chalk.red("error")} killing pid ${pid}: ${msg}`);
            }
          }
        }

        // 2. Remove the worktree
        if (run.worktree_path) {
          console.log(`    ${chalk.yellow("remove")} worktree ${run.worktree_path}`);
          if (!dryRun) {
            try {
              await removeWorktree(projectPath, run.worktree_path);
              worktreesRemoved++;
            } catch (err: unknown) {
              const msg = err instanceof Error ? err.message : String(err);
              // Worktree may already be gone
              if (!msg.includes("is not a working tree")) {
                errors.push(`Failed to remove worktree for ${run.seed_id}: ${msg}`);
                console.log(`    ${chalk.red("error")} removing worktree: ${msg}`);
              } else {
                worktreesRemoved++;
              }
            }
          }
        }

        // 3. Delete the branch
        console.log(`    ${chalk.yellow("delete")} branch ${branchName}`);
        if (!dryRun) {
          try {
            const delResult = await deleteBranch(projectPath, branchName, { force: true });
            if (delResult.deleted) branchesDeleted++;
          } catch (err: unknown) {
            const msg = err instanceof Error ? err.message : String(err);
            errors.push(`Failed to delete branch ${branchName}: ${msg}`);
            console.log(`    ${chalk.red("error")} deleting branch: ${msg}`);
          }
        }

        // 4. Mark run as failed in store
        if (run.status !== "failed") {
          console.log(`    ${chalk.yellow("mark")} run as failed`);
          if (!dryRun) {
            store.updateRun(run.id, {
              status: "failed",
              completed_at: new Date().toISOString(),
            });
            runsMarkedFailed++;
          }
        }

        seedIds.add(run.seed_id);
        console.log();
      }

      // 5. Reset seeds to open
      for (const seedId of seedIds) {
        console.log(`  ${chalk.yellow("reset")} seed ${chalk.cyan(seedId)} → open`);
        if (!dryRun) {
          try {
            await seeds.update(seedId, { status: "open" });
            seedsReset++;
          } catch (err: unknown) {
            const msg = err instanceof Error ? err.message : String(err);
            if (msg.includes("not found") || msg.includes("Issue not found")) {
              console.log(`    ${chalk.dim("skip")} seed ${seedId} no longer exists`);
            } else {
              errors.push(`Failed to reset seed ${seedId}: ${msg}`);
              console.log(`    ${chalk.red("error")} resetting seed: ${msg}`);
            }
          }
        }
      }

      // 6. Prune stale worktree entries
      if (!dryRun) {
        try {
          const { execFile } = await import("node:child_process");
          const { promisify } = await import("node:util");
          await promisify(execFile)("git", ["worktree", "prune"], { cwd: projectPath });
        } catch {
          // Non-critical
        }
      }

      // 7. Kill all foreman tmux sessions
      if (!dryRun) {
        const tmuxResult = await cleanupTmuxSessions(tmux);
        if (!tmuxResult.skipped && tmuxResult.killed > 0) {
          console.log(`\n  ${chalk.yellow("Killed")} ${tmuxResult.killed} tmux session(s)`);
        }
      }

      // 8. Detect and fix seed/run state mismatches for terminal runs
      console.log(chalk.bold("\nChecking for seed/run state mismatches..."));
      const mismatchResult = await detectAndFixMismatches(store, seeds, project.id, seedIds, { dryRun });

      if (mismatchResult.mismatches.length > 0) {
        for (const m of mismatchResult.mismatches) {
          const action = dryRun
            ? chalk.yellow("(would fix)")
            : chalk.green("fixed");
          console.log(
            `  ${chalk.yellow("mismatch")} ${chalk.cyan(m.seedId)}: ` +
            `run=${m.runStatus}, seed=${m.actualSeedStatus} → ${m.expectedSeedStatus} ${action}`,
          );
        }
      } else {
        console.log(chalk.dim("  No mismatches found."));
      }

      // Summary
      console.log(chalk.bold("\nSummary:"));
      if (dryRun) {
        console.log(chalk.yellow(`  Would reset ${runs.length} runs across ${seedIds.size} seeds`));
        if (mismatchResult.mismatches.length > 0) {
          console.log(chalk.yellow(`  Would fix ${mismatchResult.mismatches.length} mismatch(es)`));
        }
      } else {
        console.log(`  Processes killed:   ${killed}`);
        console.log(`  Worktrees removed:  ${worktreesRemoved}`);
        console.log(`  Branches deleted:   ${branchesDeleted}`);
        console.log(`  Runs marked failed: ${runsMarkedFailed}`);
        console.log(`  Seeds reset:        ${seedsReset}`);
        console.log(`  Mismatches fixed:   ${mismatchResult.fixed}`);
      }

      const allErrors = [...errors, ...mismatchResult.errors];
      if (allErrors.length > 0) {
        console.log(chalk.red(`\n  Errors (${allErrors.length}):`));
        for (const err of allErrors) {
          console.log(chalk.red(`    ${err}`));
        }
      }

      console.log(chalk.dim("\nRe-run with: foreman run"));

      store.close();
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${message}`));
      process.exit(1);
    }
  });

// ── Tmux cleanup ─────────────────────────────────────────────────────────

export interface TmuxCleanupResult {
  killed: number;
  errors: number;
  skipped: boolean;
}

/**
 * Kill all foreman-* tmux sessions.
 * Skips silently if tmux is unavailable.
 * Individual kill failures do not abort the loop.
 */
export async function cleanupTmuxSessions(
  tmux: Pick<TmuxClient, "isAvailable" | "listForemanSessions" | "killSession">,
): Promise<TmuxCleanupResult> {
  const available = await tmux.isAvailable();
  if (!available) {
    return { killed: 0, errors: 0, skipped: true };
  }

  const sessions = await tmux.listForemanSessions();
  let killed = 0;
  let errors = 0;

  for (const session of sessions) {
    const success = await tmux.killSession(session.sessionName);
    if (success) {
      killed++;
    } else {
      errors++;
    }
  }

  return { killed, errors, skipped: false };
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
