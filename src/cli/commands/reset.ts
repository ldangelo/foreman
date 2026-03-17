import { Command } from "commander";
import chalk from "chalk";

import { BeadsRustClient } from "../../lib/beads-rust.js";
import { ForemanStore } from "../../lib/store.js";
import type { Run } from "../../lib/store.js";
import { getRepoRoot } from "../../lib/git.js";
import { removeWorktree, deleteBranch, listWorktrees } from "../../lib/git.js";
import { TmuxClient } from "../../lib/tmux.js";
import type { UpdateOptions } from "../../lib/task-client.js";

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
 * For each mismatch found, the seed status is updated to the expected value
 * (unless dryRun is true).
 */
export async function detectAndFixMismatches(
  store: Pick<ForemanStore, "getRunsByStatus">,
  seeds: IShowUpdateClient,
  projectId: string,
  resetSeedIds: ReadonlySet<string>,
  opts?: { dryRun?: boolean },
): Promise<MismatchResult> {
  const dryRun = opts?.dryRun ?? false;

  // Check terminal run statuses not already handled by the reset loop
  const checkStatuses = ["completed", "merged", "pr-created", "conflict", "test-failed"] as const;
  const terminalRuns = checkStatuses.flatMap((s) => store.getRunsByStatus(s, projectId));

  // Deduplicate by seed_id: keep the most recently created run per seed
  const latestBySeed = new Map<string, Run>();
  for (const run of terminalRuns) {
    // Skip seeds already being reset by the main loop
    if (resetSeedIds.has(run.seed_id)) continue;

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

export const resetCommand = new Command("reset")
  .description("Reset failed/stuck runs: kill agents, remove worktrees, reset beads to open")
  .option("--all", "Reset ALL active runs, not just failed/stuck ones")
  .option("--dry-run", "Show what would be reset without doing it")
  .action(async (opts) => {
    const dryRun = opts.dryRun as boolean | undefined;
    const all = opts.all as boolean | undefined;

    try {
      const projectPath = await getRepoRoot(process.cwd());
      const seeds: IShowUpdateClient = new BeadsRustClient(projectPath);
      const store = ForemanStore.forProject(projectPath);
      const project = store.getProjectByPath(projectPath);

      if (!project) {
        console.error(chalk.red("No project registered for this path. Run 'foreman init' first."));
        process.exit(1);
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
        const tmux = new TmuxClient();
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
