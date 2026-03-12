import { Command } from "commander";
import chalk from "chalk";

import { BeadsClient } from "../../lib/beads.js";
import { ForemanStore } from "../../lib/store.js";
import { getRepoRoot } from "../../lib/git.js";
import { removeWorktree, deleteBranch, listWorktrees } from "../../lib/git.js";

export const resetCommand = new Command("reset")
  .description("Reset failed/stuck runs: kill agents, remove worktrees, reset seeds to open")
  .option("--all", "Reset ALL active runs, not just failed/stuck ones")
  .option("--dry-run", "Show what would be reset without doing it")
  .action(async (opts) => {
    const dryRun = opts.dryRun as boolean | undefined;
    const all = opts.all as boolean | undefined;

    try {
      const projectPath = await getRepoRoot(process.cwd());
      const beads = new BeadsClient(projectPath);
      const store = new ForemanStore();
      const project = store.getProjectByPath(projectPath);

      if (!project) {
        console.error(chalk.red("No project registered for this path. Run 'foreman init' first."));
        process.exit(1);
      }

      // Find runs to reset
      const statuses = all
        ? ["pending", "running", "failed", "stuck"] as const
        : ["pending", "running", "failed", "stuck"] as const;

      const runs = statuses.flatMap((s) => store.getRunsByStatus(s, project.id));

      if (runs.length === 0) {
        console.log(chalk.yellow("No runs to reset."));
        store.close();
        return;
      }

      if (dryRun) {
        console.log(chalk.yellow("(dry run — no changes will be made)\n"));
      }

      console.log(chalk.bold(`Resetting ${runs.length} run(s):\n`));

      // Collect unique bead IDs to reset
      const beadIds = new Set<string>();
      let killed = 0;
      let worktreesRemoved = 0;
      let branchesDeleted = 0;
      let runsMarkedFailed = 0;
      let beadsReset = 0;
      const errors: string[] = [];

      for (const run of runs) {
        const pid = extractPid(run.session_key);
        const branchName = `foreman/${run.bead_id}`;

        console.log(`  ${chalk.cyan(run.bead_id)} ${chalk.dim(`[${run.agent_type}]`)} status=${run.status}`);

        // 1. Kill the agent process if alive
        if (pid && isAlive(pid)) {
          console.log(`    ${chalk.yellow("kill")} pid ${pid}`);
          if (!dryRun) {
            try {
              process.kill(pid, "SIGTERM");
              killed++;
            } catch (err: unknown) {
              const msg = err instanceof Error ? err.message : String(err);
              errors.push(`Failed to kill pid ${pid} for ${run.bead_id}: ${msg}`);
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
                errors.push(`Failed to remove worktree for ${run.bead_id}: ${msg}`);
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
            await deleteBranch(projectPath, branchName);
            branchesDeleted++;
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

        beadIds.add(run.bead_id);
        console.log();
      }

      // 5. Reset beads to open
      for (const beadId of beadIds) {
        console.log(`  ${chalk.yellow("reset")} bead ${chalk.cyan(beadId)} → open`);
        if (!dryRun) {
          try {
            await beads.update(beadId, { status: "open" });
            beadsReset++;
          } catch (err: unknown) {
            const msg = err instanceof Error ? err.message : String(err);
            errors.push(`Failed to reset bead ${beadId}: ${msg}`);
            console.log(`    ${chalk.red("error")} resetting bead: ${msg}`);
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

      // Summary
      console.log(chalk.bold("\nSummary:"));
      if (dryRun) {
        console.log(chalk.yellow(`  Would reset ${runs.length} runs across ${beadIds.size} beads`));
      } else {
        console.log(`  Processes killed:   ${killed}`);
        console.log(`  Worktrees removed:  ${worktreesRemoved}`);
        console.log(`  Branches deleted:   ${branchesDeleted}`);
        console.log(`  Runs marked failed: ${runsMarkedFailed}`);
        console.log(`  Seeds reset:        ${beadsReset}`);
      }

      if (errors.length > 0) {
        console.log(chalk.red(`\n  Errors (${errors.length}):`));
        for (const err of errors) {
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
