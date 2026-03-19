import { Command } from "commander";
import chalk from "chalk";
import { execFile, execFileSync } from "node:child_process";
import { promisify } from "node:util";
import { join } from "node:path";
import { homedir } from "node:os";

import { BeadsRustClient } from "../../lib/beads-rust.js";
import type { ITaskClient } from "../../lib/task-client.js";
import { ForemanStore } from "../../lib/store.js";
import { getRepoRoot, detectDefaultBranch } from "../../lib/git.js";
import { Refinery, dryRunMerge } from "../../orchestrator/refinery.js";
import { MergeQueue } from "../../orchestrator/merge-queue.js";
import type { MergeQueueStatus } from "../../orchestrator/merge-queue.js";
import type { MergedRun, ConflictRun, FailedRun, CreatedPr } from "../../orchestrator/types.js";
import { MergeCostTracker } from "../../orchestrator/merge-cost-tracker.js";
import { mapRunStatusToSeedStatus } from "../../lib/run-status.js";
import { PIPELINE_TIMEOUTS } from "../../lib/config.js";

// ── Bead status sync helpers ───────────────────────────────────────────

/** Absolute path to the br binary (mirrors task-backend-ops.ts). */
function brPath(): string {
  return join(homedir(), ".local", "bin", "br");
}

/**
 * Immediately sync a bead's status in the br backend after a merge outcome.
 *
 * Fetches the latest run status from SQLite, maps it to the expected bead
 * status via mapRunStatusToSeedStatus(), updates br, then flushes with
 * `br sync --flush-only`.
 *
 * Non-fatal — logs a warning on failure and lets the caller continue.
 */
async function syncBeadStatusAfterMerge(
  store: ForemanStore,
  seeds: ITaskClient,
  runId: string,
  seedId: string,
  projectPath: string,
): Promise<void> {
  const run = store.getRun(runId);
  if (!run) return;

  const expectedStatus = mapRunStatusToSeedStatus(run.status);
  try {
    await seeds.update(seedId, { status: expectedStatus });
    execFileSync(brPath(), ["sync", "--flush-only"], {
      stdio: "pipe",
      timeout: PIPELINE_TIMEOUTS.beadClosureMs,
      cwd: projectPath,
    });
  } catch (syncErr: unknown) {
    const msg = syncErr instanceof Error ? syncErr.message : String(syncErr);
    console.warn(chalk.yellow(`  [merge] Warning: Failed to sync bead status for ${seedId}: ${msg}`));
  }
}

// ── Backend Client Factory (TRD-017) ──────────────────────────────────

/**
 * Instantiate the br task-tracking client.
 *
 * TRD-024: sd backend removed. Always returns a BeadsRustClient after verifying
 * the binary exists.
 *
 * Throws if the br binary cannot be found.
 */
export async function createMergeTaskClient(projectPath: string): Promise<ITaskClient> {
  const brClient = new BeadsRustClient(projectPath);
  // Verify binary exists before proceeding; throws with a friendly message if not
  await brClient.ensureBrInstalled();
  return brClient;
}

const execFileAsync = promisify(execFile);

/** Status label with color for queue display. */
function statusLabel(status: MergeQueueStatus): string {
  switch (status) {
    case "pending":  return chalk.yellow("pending");
    case "merging":  return chalk.blue("merging");
    case "merged":   return chalk.green("merged");
    case "conflict": return chalk.red("conflict");
    case "failed":   return chalk.red("failed");
  }
}

export const mergeCommand = new Command("merge")
  .description("Merge completed agent work into target branch")
  .option("--target-branch <branch>", "Branch to merge into (default: auto-detected)")
  .option("--no-tests", "Skip running tests after merge")
  .option("--test-command <cmd>", "Test command to run", "npm test")
  .option("--seed <id>", "Merge a single seed by ID")
  .option("--list", "List seeds ready to merge (no merge performed)")
  .option("--dry-run", "Preview merge results without modifying git state")
  .option("--resolve <runId>", "Resolve a conflicting run by ID")
  .option("--strategy <strategy>", "Conflict resolution strategy: theirs|abort")
  .option("--auto-retry", "Automatically retry failed/conflict entries using exponential backoff")
  .option("--stats [period]", "Show merge cost statistics (daily|weekly|monthly|all)")
  .option("--json", "Output stats in JSON format")
  .action(async (opts) => {
    try {
      const projectPath = await getRepoRoot(process.cwd());

      // Resolve the target branch: use the explicit --target-branch flag if provided,
      // otherwise auto-detect the repository's default branch.
      const targetBranch: string = (opts.targetBranch as string | undefined)
        ?? await detectDefaultBranch(projectPath);

      const seeds = await createMergeTaskClient(projectPath);
      const store = ForemanStore.forProject(projectPath);
      const refinery = new Refinery(store, seeds, projectPath);
      const mq = new MergeQueue(store.getDb());

      const project = store.getProjectByPath(projectPath);
      if (!project) {
        if (opts.json) {
          console.error(JSON.stringify({ error: "No project registered. Run 'foreman init' first." }));
        } else {
          console.error(chalk.red("No project registered. Run 'foreman init' first."));
        }
        process.exit(1);
      }

      // --resolve mode: resolve a conflicting run (unchanged)
      if (opts.resolve) {
        if (!opts.strategy) {
          console.error(chalk.red("Error: --strategy <theirs|abort> is required when using --resolve"));
          store.close();
          process.exit(1);
        }

        const strategy = opts.strategy as string;
        if (strategy !== "theirs" && strategy !== "abort") {
          console.error(chalk.red(`Error: Invalid strategy '${strategy}'. Must be 'theirs' or 'abort'.`));
          store.close();
          process.exit(1);
        }

        const runId = opts.resolve as string;
        const run = store.getRun(runId);
        if (!run) {
          console.error(chalk.red(`Error: Run '${runId}' not found.`));
          store.close();
          process.exit(1);
        }

        if (run.status !== "conflict") {
          console.error(
            chalk.red(
              `Error: Run '${runId}' is not in conflict state (current status: '${run.status}'). Only runs with status 'conflict' can be resolved.`,
            ),
          );
          store.close();
          process.exit(1);
        }

        const branchName = `foreman/${run.seed_id}`;
        console.log(chalk.bold(`Resolving conflict for ${chalk.cyan(run.seed_id)} (${branchName}) with strategy: ${chalk.yellow(strategy)}\n`));

        const success = await refinery.resolveConflict(runId, strategy as "theirs" | "abort", {
          targetBranch,
          runTests: opts.tests,
          testCommand: opts.testCommand,
        });

        if (success) {
          console.log(chalk.green.bold(`Conflict resolved -- ${run.seed_id} merged successfully.`));
        } else if (strategy === "abort") {
          console.log(chalk.yellow(`Merge aborted -- ${run.seed_id} marked as failed.`));
        } else {
          console.log(chalk.red(`Failed to resolve conflict for ${run.seed_id} -- marked as failed.`));
        }

        store.close();
        return;
      }

      // --stats: show merge cost statistics (MQ-T071)
      if (opts.stats !== undefined) {
        const costTracker = new MergeCostTracker(store.getDb());
        const period = (typeof opts.stats === "string" ? opts.stats : "all") as "daily" | "weekly" | "monthly" | "all";
        const stats = costTracker.getStats(period);

        if (opts.json) {
          console.log(JSON.stringify(stats, null, 2));
        } else {
          console.log(chalk.bold(`Merge cost statistics (${period}):\n`));
          console.log(`  Total cost:     $${stats.totalCostUsd.toFixed(4)}`);
          console.log(`  Input tokens:   ${stats.totalInputTokens.toLocaleString()}`);
          console.log(`  Output tokens:  ${stats.totalOutputTokens.toLocaleString()}`);
          console.log(`  Entries:        ${stats.entryCount}`);

          if (Object.keys(stats.byTier).length > 0) {
            console.log(chalk.bold("\n  By tier:"));
            for (const [tier, breakdown] of Object.entries(stats.byTier)) {
              console.log(`    Tier ${tier}: ${breakdown.count} calls, $${breakdown.totalCostUsd.toFixed(4)}`);
            }
          }

          if (Object.keys(stats.byModel).length > 0) {
            console.log(chalk.bold("\n  By model:"));
            for (const [model, breakdown] of Object.entries(stats.byModel)) {
              console.log(`    ${model}: ${breakdown.count} calls, $${breakdown.totalCostUsd.toFixed(4)}`);
            }
          }

          // Resolution rate (MQ-T072)
          const rate = costTracker.getResolutionRate(30);
          if (rate.total > 0) {
            console.log(chalk.bold("\n  AI resolution rate (30 days):"));
            console.log(`    ${rate.successes}/${rate.total} conflicts (${rate.rate.toFixed(1)}%)`);
          }
        }

        store.close();
        return;
      }

      // --dry-run: preview merge without modifying git state (MQ-T058)
      if (opts.dryRun) {
        // Reconcile first to get current queue state
        const reconcileResult = await mq.reconcile(store.getDb(), projectPath, execFileAsync);
        if (reconcileResult.enqueued > 0) {
          console.log(chalk.dim(`  (reconciled ${reconcileResult.enqueued} new entry/entries into queue)\n`));
        }

        const entries = mq.list();
        const branches = entries.map((e) => ({
          branchName: e.branch_name,
          seedId: e.seed_id,
        }));

        if (branches.length === 0) {
          console.log(chalk.yellow("No branches in merge queue to preview."));
          store.close();
          return;
        }

        console.log(chalk.bold("Dry-run merge preview:\n"));

        const dryRunResults = await dryRunMerge(
          projectPath,
          targetBranch,
          branches,
          opts.seed as string | undefined,
        );

        for (const entry of dryRunResults) {
          const conflictIcon = entry.hasConflicts
            ? chalk.red("CONFLICT")
            : chalk.green("OK");
          const tierStr =
            entry.estimatedTier !== undefined
              ? chalk.dim(` [tier ${entry.estimatedTier}]`)
              : "";

          console.log(`  ${conflictIcon}${tierStr} ${chalk.cyan(entry.seedId)} ${chalk.dim(entry.branchName)}`);

          if (entry.error) {
            console.log(`    ${chalk.red(entry.error)}`);
          } else if (entry.diffStat) {
            for (const line of entry.diffStat.split("\n")) {
              console.log(`    ${chalk.dim(line)}`);
            }
          }
          console.log();
        }

        console.log(chalk.dim("No git state was modified."));
        store.close();
        return;
      }

      // --list: show queue entries and exit (MQ-T019)
      if (opts.list) {
        // Reconcile first to ensure queue is up to date
        const reconcileResult = await mq.reconcile(store.getDb(), projectPath, execFileAsync);

        const entries = mq.list();

        if (opts.json) {
          console.log(JSON.stringify({ entries }, null, 2));
          store.close();
          return;
        }

        if (reconcileResult.enqueued > 0) {
          console.log(chalk.dim(`  (reconciled ${reconcileResult.enqueued} new entry/entries into queue)\n`));
        }

        if (entries.length === 0) {
          console.log(chalk.yellow("No seeds in merge queue."));
          store.close();
          return;
        }

        console.log(chalk.bold(`Merge queue (${entries.length} entries):\n`));

        for (let i = 0; i < entries.length; i++) {
          const entry = entries[i];
          const elapsed = Math.round(
            (Date.now() - new Date(entry.enqueued_at).getTime()) / 60000,
          );
          const filesCount = entry.files_modified.length;
          const num = `${i + 1}`.padStart(2);
          console.log(
            `  ${chalk.dim(num + ".")} ${statusLabel(entry.status)} ${chalk.cyan(entry.seed_id)} ${chalk.dim(entry.branch_name)} ${chalk.dim(`(${elapsed}m ago, ${filesCount} files)`)}`,
          );
          if (entry.error) {
            console.log(`      ${chalk.dim(entry.error)}`);
          }
        }

        console.log(chalk.dim("\nMerge all:    foreman merge"));
        console.log(chalk.dim("Merge one:    foreman merge --seed <id>"));

        store.close();
        return;
      }

      // ── Main merge flow (MQ-T018): queue-based ────────────────────────

      console.log(chalk.bold("Running refinery on completed work...\n"));

      // Step 1: Reconcile — ensure all completed runs are in the queue
      const reconcileResult = await mq.reconcile(store.getDb(), projectPath, execFileAsync);
      if (reconcileResult.enqueued > 0) {
        console.log(chalk.dim(`  Reconciled ${reconcileResult.enqueued} completed run(s) into merge queue.\n`));
      }
      if (reconcileResult.failedToEnqueue.length > 0) {
        console.log(chalk.yellow(`  Warning: ${reconcileResult.failedToEnqueue.length} completed run(s) could not be enqueued (branch missing):`));
        for (const failed of reconcileResult.failedToEnqueue) {
          console.log(chalk.yellow(`    - ${failed.seed_id}: ${failed.reason}`));
        }
        console.log();
      }

      // When retrying a specific seed, reset its failed/conflict entry back to
      // pending so the dequeue loop can pick it up again.
      if (opts.seed) {
        mq.resetForRetry(opts.seed);
      }

      // Step 2: Process queue via dequeue loop
      const merged: MergedRun[] = [];
      const conflicts: ConflictRun[] = [];
      const testFailures: FailedRun[] = [];
      const prsCreated: CreatedPr[] = [];
      const skippedIds: number[] = []; // entries skipped due to --seed filter

      let entry = mq.dequeue();
      while (entry) {
        // If --seed filter is active, skip non-matching entries
        if (opts.seed && entry.seed_id !== opts.seed) {
          skippedIds.push(entry.id);
          entry = mq.dequeue();
          continue;
        }

        console.log(`Processing: ${chalk.cyan(entry.seed_id)} (${chalk.dim(entry.branch_name)})`);

        try {
          const report = await refinery.mergeCompleted({
            targetBranch,
            runTests: opts.tests,
            testCommand: opts.testCommand,
            projectId: project.id,
            seedId: entry.seed_id,
          });

          if (report.merged.length > 0) {
            mq.updateStatus(entry.id, "merged", { completedAt: new Date().toISOString() });
            merged.push(...report.merged);
          } else if (report.conflicts.length > 0 || report.prsCreated.length > 0) {
            mq.updateStatus(entry.id, "conflict", { error: "Code conflicts" });
            conflicts.push(...report.conflicts);
            prsCreated.push(...report.prsCreated);
          } else if (report.testFailures.length > 0) {
            mq.updateStatus(entry.id, "failed", { error: "Test failures" });
            testFailures.push(...report.testFailures);
          } else {
            // No completed run found for this seed (already merged or no run)
            mq.updateStatus(entry.id, "failed", { error: "No completed run found" });
          }

          // Immediately sync bead status in br so it reflects the merge outcome
          // without waiting for the next foreman startup reconciliation.
          await syncBeadStatusAfterMerge(store, seeds, entry.run_id, entry.seed_id, projectPath);
        } catch (err: unknown) {
          const message = err instanceof Error ? err.message : String(err);
          mq.updateStatus(entry.id, "failed", { error: message });
          testFailures.push({
            runId: entry.run_id,
            seedId: entry.seed_id,
            branchName: entry.branch_name,
            error: message,
          });
          // Sync bead status even when refinery throws (run may have been updated before exception)
          await syncBeadStatusAfterMerge(store, seeds, entry.run_id, entry.seed_id, projectPath);
        }

        // If --seed filter, stop after processing the target
        if (opts.seed) {
          break;
        }

        // Re-reconcile to catch agents that completed during this merge iteration.
        // This handles the race condition where an agent finishes after the initial
        // reconcile snapshot but before the dequeue loop exhausts the queue.
        try {
          const midLoopResult = await mq.reconcile(store.getDb(), projectPath, execFileAsync);
          if (midLoopResult.enqueued > 0) {
            console.log(chalk.dim(`  Reconciled ${midLoopResult.enqueued} additional completed run(s) into merge queue.\n`));
          }
        } catch (reconcileErr: unknown) {
          const reconcileMessage = reconcileErr instanceof Error ? reconcileErr.message : String(reconcileErr);
          console.warn(chalk.yellow(`  Warning: mid-loop reconcile failed (${reconcileMessage}); continuing with existing queue entries.`));
        }

        entry = mq.dequeue();
      }

      // Reset skipped entries back to pending (for --seed filter)
      for (const id of skippedIds) {
        mq.updateStatus(id, "pending");
      }

      // ── Auto-retry loop ──────────────────────────────────────────────────
      if (opts.autoRetry && !opts.seed) {
        const retryable = mq.getRetryableEntries();
        if (retryable.length > 0) {
          console.log(chalk.dim(`\n  Retrying ${retryable.length} failed/conflict entry(ies)...\n`));
          for (const retryEntry of retryable) {
            if (mq.reEnqueue(retryEntry.id)) {
              console.log(`Retrying: ${chalk.cyan(retryEntry.seed_id)} (attempt ${retryEntry.retry_count + 1})`);
              const toProcess = mq.dequeue();
              if (!toProcess) continue;

              try {
                const report = await refinery.mergeCompleted({
                  targetBranch,
                  runTests: opts.tests,
                  testCommand: opts.testCommand,
                  projectId: project.id,
                  seedId: toProcess.seed_id,
                });

                if (report.merged.length > 0) {
                  mq.updateStatus(toProcess.id, "merged", { completedAt: new Date().toISOString() });
                  merged.push(...report.merged);
                } else if (report.conflicts.length > 0 || report.prsCreated.length > 0) {
                  mq.updateStatus(toProcess.id, "conflict", { error: "Code conflicts" });
                  conflicts.push(...report.conflicts);
                  prsCreated.push(...report.prsCreated);
                } else if (report.testFailures.length > 0) {
                  mq.updateStatus(toProcess.id, "failed", { error: "Test failures" });
                  testFailures.push(...report.testFailures);
                } else {
                  mq.updateStatus(toProcess.id, "failed", { error: "No completed run found" });
                }
              } catch (err: unknown) {
                const message = err instanceof Error ? err.message : String(err);
                mq.updateStatus(toProcess.id, "failed", { error: message });
                testFailures.push({
                  runId: toProcess.run_id,
                  seedId: toProcess.seed_id,
                  branchName: toProcess.branch_name,
                  error: message,
                });
              }
            }
          }
        }
      }

      // ── Display results ─────────────────────────────────────────────

      if (merged.length > 0) {
        console.log(chalk.green.bold(`\nMerged ${merged.length} task(s):\n`));
        for (const m of merged) {
          console.log(`  ${chalk.cyan(m.seedId)} ${m.branchName}`);
        }
        console.log();
      }

      if (conflicts.length > 0) {
        console.log(chalk.yellow.bold(`Conflicts in ${conflicts.length} task(s):\n`));
        for (const c of conflicts) {
          console.log(`  ${chalk.cyan(c.seedId)} ${c.branchName}`);
          for (const f of c.conflictFiles) {
            console.log(`    ${chalk.dim(f)}`);
          }
        }
        console.log();
        console.log(
          chalk.dim("  Resolve with: foreman merge --resolve <runId> --strategy theirs|abort"),
        );
        console.log();
      }

      if (prsCreated.length > 0) {
        console.log(chalk.blue.bold(`PRs created for ${prsCreated.length} conflicting task(s):\n`));
        for (const pr of prsCreated) {
          console.log(`  ${chalk.cyan(pr.seedId)} ${chalk.dim(pr.branchName)}`);
          console.log(`    ${chalk.underline(pr.prUrl)}`);
        }
        console.log();
      }

      if (testFailures.length > 0) {
        console.log(chalk.red.bold(`Test failures in ${testFailures.length} task(s):\n`));
        for (const f of testFailures) {
          console.log(`  ${chalk.cyan(f.seedId)} ${f.branchName}`);
          console.log(`    ${chalk.dim(f.error.split("\n")[0])}`);
        }
        console.log();
      }

      // Display running AI resolution rate after merge (MQ-T072)
      if (merged.length > 0 || conflicts.length > 0) {
        try {
          const costTracker = new MergeCostTracker(store.getDb());
          const rate = costTracker.getResolutionRate(30);
          if (rate.total > 0) {
            console.log(
              chalk.dim(`AI resolution rate: ${rate.successes}/${rate.total} conflicts (${rate.rate.toFixed(1)}%) over last 30 days\n`),
            );
          }
        } catch {
          // Cost tracking tables may not exist yet — silently skip
        }
      }

      if (merged.length === 0 && conflicts.length === 0 && testFailures.length === 0 && prsCreated.length === 0) {
        if (opts.seed) {
          console.log(chalk.yellow(`No completed run found for seed ${opts.seed}.`));
          console.log(chalk.dim("Use 'foreman merge --list' to see seeds ready to merge."));
        } else {
          console.log(chalk.yellow("No completed tasks to merge."));
        }
      }

      store.close();
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      if (opts.json) {
        console.error(JSON.stringify({ error: message }));
      } else {
        console.error(chalk.red(`Error: ${message}`));
      }
      process.exit(1);
    }
  });
