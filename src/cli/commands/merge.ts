import { Command } from "commander";
import chalk from "chalk";

import { loadProjectConfig, resolveDefaultBranch, resolveVcsConfig } from "../../lib/project-config.js";
import { createTaskClient } from "../../lib/task-client-factory.js";
import type { ITaskClient } from "../../lib/task-client.js";
import { ForemanStore } from "../../lib/store.js";
import { ElixirCliStore } from "./elixir-cli-store.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import type { VcsBackend } from "../../lib/vcs/interface.js";
import { Refinery, dryRunMerge } from "../../orchestrator/refinery.js";
import { MergeQueue } from "../../orchestrator/merge-queue.js";
import { ElixirMergeQueue } from "./elixir-merge-queue.js";
import type { MergeQueueStatus } from "../../orchestrator/merge-queue.js";
import type { MergedRun, ConflictRun, FailedRun, CreatedPr } from "../../orchestrator/types.js";
import { MergeCostTracker } from "../../orchestrator/merge-cost-tracker.js";
import { syncTaskStatusAfterMerge } from "../../orchestrator/auto-merge.js";
import { resolveRepoRootProjectPath } from "./project-task-support.js";
import { findRegisteredProjectByPath } from "./project-context.js";

// ── Backend Client Factory (TRD-017) ──────────────────────────────────

/**
 * Instantiate the native task-tracking client.
 */
export async function createMergeTaskClient(projectPath: string, registeredProjectId?: string): Promise<ITaskClient> {
  const { taskClient } = await createTaskClient(projectPath, { registeredProjectId });
  return taskClient;
}

async function createMergeVcsBackend(projectPath: string): Promise<VcsBackend> {
  const projectCfg = loadProjectConfig(projectPath);
  const vcsConfig = resolveVcsConfig(undefined, projectCfg?.vcs);
  return VcsBackendFactory.create(vcsConfig, projectPath);
}

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

interface MergeQueueLike {
  reconcile(repoPath: string): Promise<{ enqueued: number; skipped: number; invalidBranch: number; failedToEnqueue: Array<{ run_id: string; task_id: string; reason: string }> }>;
  list(): Promise<Array<{
    id: number;
    branch_name: string;
    task_id: string;
    run_id: string;
    enqueued_at: string;
    status: MergeQueueStatus;
    files_modified: string[];
    operation?: "auto_merge" | "create_pr";
    error: string | null;
    retry_count: number;
  }>>;
  resetForRetry(taskId: string): Promise<boolean>;
  dequeue(): Promise<Awaited<ReturnType<MergeQueueLike["list"]>>[number] | null>;
  updateStatus(id: number, status: MergeQueueStatus, extra?: { resolvedTier?: number; error?: string; completedAt?: string; lastAttemptedAt?: string; retryCount?: number }): Promise<void>;
  getRetryableEntries(): Promise<Awaited<ReturnType<MergeQueueLike["list"]>>>;
  reEnqueue(id: number): Promise<boolean>;
}

function wrapLocalMergeQueue(queue: MergeQueue, store: ForemanStore, projectPath: string): MergeQueueLike {
  return {
    reconcile: async () => queue.reconcile(store.getDb(), projectPath),
    list: async () => queue.list(),
    resetForRetry: async (taskId) => queue.resetForRetry(taskId),
    dequeue: async () => queue.dequeue(),
    updateStatus: async (id, status, extra) => queue.updateStatus(id, status, extra),
    getRetryableEntries: async () => queue.getRetryableEntries(),
    reEnqueue: async (id) => queue.reEnqueue(id),
  };
}

export const mergeCommand = new Command("merge")
  .description("Merge completed agent work into target branch")
  .option("--target-branch <branch>", "Branch to merge into (default: auto-detected)")
  .option("--no-tests", "Skip running tests after merge")
  .option("--test-command <cmd>", "Test command to run", "npm test")
  .option("--task <id>", "Merge a single task by ID")
  .option("--list", "List tasks ready to merge (no merge performed)")
  .option("--dry-run", "Preview merge results without modifying git state")
  .option("--resolve <runId>", "Resolve a conflicting run by ID")
  .option("--strategy <strategy>", "Conflict resolution strategy: theirs|abort")
  .option("--auto-retry", "Automatically retry failed/conflict entries using exponential backoff")
  .option("--stats [period]", "Show merge cost statistics (daily|weekly|monthly|all)")
  .option("--json", "Output stats in JSON format")
  .action(async (opts) => {
    try {
      const projectPath = await resolveRepoRootProjectPath({});
      const projectCfg = loadProjectConfig(projectPath);
      const vcs = await createMergeVcsBackend(projectPath);
      const registered = await findRegisteredProjectByPath(projectPath);

      // Resolve the target branch: use the explicit --target-branch flag if provided,
      // otherwise auto-detect the repository's default branch.
      const targetBranch: string = (opts.targetBranch as string | undefined)
        ?? await resolveDefaultBranch(
          projectPath,
          (path) => vcs.detectDefaultBranch(path),
          projectCfg,
        );

      const store = ForemanStore.forProject(projectPath);
      const tasks = await createMergeTaskClient(projectPath, registered?.id);
      const runLookup = registered ? ElixirCliStore.forProject(registered) : undefined;
      const refinery = registered
        ? new Refinery(store, tasks, projectPath, vcs, {
          registeredProjectId: registered.id,
          runLookup,
        })
        : new Refinery(store, tasks, projectPath, vcs);
      const mq: MergeQueueLike = registered
        ? new ElixirMergeQueue(registered.id)
        : wrapLocalMergeQueue(new MergeQueue(store.getDb()), store, projectPath);

      const project = registered ?? store.getProjectByPath(projectPath);
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
        const run = registered ? await runLookup!.getRun(runId) : store.getRun(runId);
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

        const branchName = `foreman/${run.task_id}`;
        console.log(chalk.bold(`Resolving conflict for ${chalk.cyan(run.task_id)} (${branchName}) with strategy: ${chalk.yellow(strategy)}\n`));

        const success = await refinery.resolveConflict(runId, strategy as "theirs" | "abort", {
          targetBranch,
          runTests: opts.tests,
          testCommand: opts.testCommand,
        });

        if (success) {
          console.log(chalk.green.bold(`Conflict resolved -- ${run.task_id} merged successfully.`));
        } else if (strategy === "abort") {
          console.log(chalk.yellow(`Merge aborted -- ${run.task_id} marked as failed.`));
        } else {
          console.log(chalk.red(`Failed to resolve conflict for ${run.task_id} -- marked as failed.`));
        }

        store.close();
        return;
      }

      // --stats: show merge cost statistics (MQ-T071)
      if (opts.stats !== undefined) {
        if (registered) {
          console.error(chalk.red("Merge cost statistics are not exposed by the Elixir backend yet."));
          store.close();
          process.exit(1);
        }
        const costTracker = new MergeCostTracker(store.getDb());
        const period = (typeof opts.stats === "string" ? opts.stats : "all") as "daily" | "weekly" | "monthly" | "all";
        const stats = await costTracker.getStats(period as never);

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
          const rate = await costTracker.getResolutionRate(30);
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
        const reconcileResult = await mq.reconcile(projectPath);
        if (reconcileResult.enqueued > 0) {
          console.log(chalk.dim(`  (reconciled ${reconcileResult.enqueued} new entry/entries into queue)\n`));
        }

        const entries = await mq.list();
        const branches = entries.map((e) => ({
          branchName: e.branch_name,
          taskId: e.task_id,
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
          (opts.task ?? opts.task) as string | undefined,
        );

        for (const entry of dryRunResults) {
          const conflictIcon = entry.hasConflicts
            ? chalk.red("CONFLICT")
            : chalk.green("OK");
          const tierStr =
            entry.estimatedTier !== undefined
              ? chalk.dim(` [tier ${entry.estimatedTier}]`)
              : "";

          console.log(`  ${conflictIcon}${tierStr} ${chalk.cyan(entry.taskId)} ${chalk.dim(entry.branchName)}`);

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
        const reconcileResult = await mq.reconcile(projectPath);

        const entries = await mq.list();

        if (opts.json) {
          console.log(JSON.stringify({ entries }, null, 2));
          store.close();
          return;
        }

        if (reconcileResult.enqueued > 0) {
          console.log(chalk.dim(`  (reconciled ${reconcileResult.enqueued} new entry/entries into queue)\n`));
        }

        if (entries.length === 0) {
          console.log(chalk.yellow("No tasks in merge queue."));
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
            `  ${chalk.dim(num + ".")} ${statusLabel(entry.status)} ${chalk.cyan(entry.task_id)} ${chalk.dim(entry.branch_name)} ${chalk.dim(`(${elapsed}m ago, ${filesCount} files)`)}`,
          );
          if (entry.error) {
            console.log(`      ${chalk.dim(entry.error)}`);
          }
        }

        console.log(chalk.dim("\nMerge all:    foreman merge"));
        console.log(chalk.dim("Merge one:    foreman merge --task <id>"));

        store.close();
        return;
      }

      // ── Main merge flow (MQ-T018): queue-based ────────────────────────

      console.log(chalk.bold("Running refinery on completed work...\n"));

      // Step 1: Reconcile — ensure all completed runs are in the queue
        const reconcileResult = await mq.reconcile(projectPath);
      if (reconcileResult.enqueued > 0) {
        console.log(chalk.dim(`  Reconciled ${reconcileResult.enqueued} completed run(s) into merge queue.\n`));
      }
      if (reconcileResult.failedToEnqueue.length > 0) {
        console.log(chalk.yellow(`  Warning: ${reconcileResult.failedToEnqueue.length} completed run(s) could not be enqueued (branch missing):`));
        for (const failed of reconcileResult.failedToEnqueue) {
          console.log(chalk.yellow(`    - ${failed.task_id}: ${failed.reason}`));
        }
        console.log();
      }

      // When retrying a specific task, reset its failed/conflict entry back to
      // pending so the dequeue loop can pick it up again.
      const taskFilter = (opts.task ?? opts.task) as string | undefined;
      if (taskFilter) {
        await mq.resetForRetry(taskFilter);
      }

      // Step 2: Process queue via dequeue loop
      const merged: MergedRun[] = [];
      const conflicts: ConflictRun[] = [];
      const testFailures: FailedRun[] = [];
      const prsCreated: CreatedPr[] = [];
      const skippedIds: number[] = []; // entries skipped due to --task filter

      let entry = await mq.dequeue();
      while (entry) {
        // If --task filter is active, skip non-matching entries
        if (taskFilter && entry.task_id !== taskFilter) {
          skippedIds.push(entry.id);
          entry = await mq.dequeue();
          continue;
        }

        console.log(`Processing: ${chalk.cyan(entry.task_id)} (${chalk.dim(entry.branch_name)})`);

        // Track failure reason for immediate task note (declared outside try for finally access)
        let mergeFailureReason: string | undefined;
        try {
          // Fetch the run directly to bypass the getCompletedRuns() query and eliminate
          // the race condition where finalize marks a run completed but the query hasn't
          // seen the update yet.
          const run = store.getRun(entry.run_id);
                const report = await refinery.mergeCompleted({
                  targetBranch,
                  runTests: opts.tests,
                  testCommand: opts.testCommand,
                  projectId: registered?.id ?? project.id,
                  taskId: entry.task_id,
                  overrideRun: run ?? undefined,
                });

          if (report.merged.length > 0) {
            await mq.updateStatus(entry.id, "merged", { completedAt: new Date().toISOString() });
            merged.push(...report.merged);
          } else if (report.conflicts.length > 0 || report.prsCreated.length > 0) {
            await mq.updateStatus(entry.id, "conflict", { error: "Code conflicts" });
            conflicts.push(...report.conflicts);
            prsCreated.push(...report.prsCreated);
            // Build failure reason for task note
            if (report.conflicts.length > 0) {
              const files = report.conflicts.flatMap((c) => c.conflictFiles).slice(0, 10);
              mergeFailureReason = `Merge conflict detected in branch foreman/${entry.task_id}.\nConflicting files:\n${files.map((f) => `  - ${f}`).join("\n") || "  (no file details available)"}`;
            } else if (report.prsCreated.length > 0) {
              const pr = report.prsCreated[0];
              mergeFailureReason = `Merge conflict: a PR was created for manual review.\nPR URL: ${pr.prUrl}\nBranch: ${pr.branchName}`;
            }
          } else if (report.testFailures.length > 0) {
            await mq.updateStatus(entry.id, "failed", { error: "Test failures" });
            testFailures.push(...report.testFailures);
            // Build failure reason for task note
            const firstFailure = report.testFailures[0];
            const errorSummary = firstFailure.error?.slice(0, 800) ?? "no details";
            mergeFailureReason = `Post-merge tests failed (${report.testFailures.length} failure(s)).\nFirst failure:\n${errorSummary}`;
          } else {
            // No completed run found for this task (already merged or no run)
            await mq.updateStatus(entry.id, "failed", { error: "No completed run found" });
            mergeFailureReason = `Merge failed: no completed run found for task ${entry.task_id}. The run may have been deleted or not yet finalized.`;
          }
        } catch (err: unknown) {
          const message = err instanceof Error ? err.message : String(err);
          await mq.updateStatus(entry.id, "failed", { error: message });
          testFailures.push({
            runId: entry.run_id,
            taskId: entry.task_id,
            branchName: entry.branch_name,
            error: message,
          });
          mergeFailureReason = `Unexpected error during merge: ${message.slice(0, 800)}`;
        } finally {
          // Immediately sync task status in native task store so it reflects the merge outcome
          // without waiting for the next foreman startup reconciliation.
          // Pass mergeFailureReason to add an explanatory note to the task.
          await syncTaskStatusAfterMerge(store, tasks, entry.run_id, entry.task_id, projectPath, mergeFailureReason, runLookup);
        }

        // If --task filter, stop after processing the target
        if (taskFilter) {
          break;
        }

        // Re-reconcile to catch agents that completed during this merge iteration.
        // This handles the race condition where an agent finishes after the initial
        // reconcile snapshot but before the dequeue loop exhausts the queue.
        try {
          const midLoopResult = await mq.reconcile(projectPath);
          if (midLoopResult.enqueued > 0) {
            console.log(chalk.dim(`  Reconciled ${midLoopResult.enqueued} additional completed run(s) into merge queue.\n`));
          }
        } catch (reconcileErr: unknown) {
          const reconcileMessage = reconcileErr instanceof Error ? reconcileErr.message : String(reconcileErr);
          console.warn(chalk.yellow(`  Warning: mid-loop reconcile failed (${reconcileMessage}); continuing with existing queue entries.`));
        }

        entry = await mq.dequeue();
      }

      // Reset skipped entries back to pending (for --task filter)
      for (const id of skippedIds) {
        await mq.updateStatus(id, "pending");
      }

      // ── Auto-retry loop ──────────────────────────────────────────────────
      if (opts.autoRetry && !taskFilter) {
        const retryable = await mq.getRetryableEntries();
        if (retryable.length > 0) {
          console.log(chalk.dim(`\n  Retrying ${retryable.length} failed/conflict entry(ies)...\n`));
          for (const retryEntry of retryable) {
            if (await mq.reEnqueue(retryEntry.id)) {
              console.log(`Retrying: ${chalk.cyan(retryEntry.task_id)} (attempt ${retryEntry.retry_count + 1})`);
              const toProcess = await mq.dequeue();
              if (!toProcess) continue;

              let retryFailureReason: string | undefined;
              try {
                // Fetch the run directly to bypass the getCompletedRuns() query and eliminate
                // the race condition where finalize marks a run completed but the query hasn't
                // seen the update yet.
                const run = store.getRun(toProcess.run_id);
                const report = await refinery.mergeCompleted({
                  targetBranch,
                  runTests: opts.tests,
                  testCommand: opts.testCommand,
                  projectId: registered?.id ?? project.id,
                  taskId: toProcess.task_id,
                  overrideRun: run ?? undefined,
                });

                if (report.merged.length > 0) {
                  await mq.updateStatus(toProcess.id, "merged", { completedAt: new Date().toISOString() });
                  merged.push(...report.merged);
                } else if (report.conflicts.length > 0 || report.prsCreated.length > 0) {
                  await mq.updateStatus(toProcess.id, "conflict", { error: "Code conflicts" });
                  conflicts.push(...report.conflicts);
                  prsCreated.push(...report.prsCreated);
                  if (report.conflicts.length > 0) {
                    const files = report.conflicts.flatMap((c) => c.conflictFiles).slice(0, 10);
                    retryFailureReason = `Merge conflict (retry) in branch foreman/${toProcess.task_id}.\nConflicting files:\n${files.map((f) => `  - ${f}`).join("\n") || "  (no file details available)"}`;
                  } else if (report.prsCreated.length > 0) {
                    const pr = report.prsCreated[0];
                    retryFailureReason = `Merge conflict (retry): a PR was created for manual review.\nPR URL: ${pr.prUrl}\nBranch: ${pr.branchName}`;
                  }
                } else if (report.testFailures.length > 0) {
                  await mq.updateStatus(toProcess.id, "failed", { error: "Test failures" });
                  testFailures.push(...report.testFailures);
                  const firstFailure = report.testFailures[0];
                  retryFailureReason = `Post-merge tests failed on retry (${report.testFailures.length} failure(s)).\nFirst failure:\n${firstFailure.error?.slice(0, 800) ?? "no details"}`;
                } else {
                  await mq.updateStatus(toProcess.id, "failed", { error: "No completed run found" });
                  retryFailureReason = `Merge failed on retry: no completed run found for task ${toProcess.task_id}.`;
                }
              } catch (err: unknown) {
                const message = err instanceof Error ? err.message : String(err);
                await mq.updateStatus(toProcess.id, "failed", { error: message });
                testFailures.push({
                  runId: toProcess.run_id,
                  taskId: toProcess.task_id,
                  branchName: toProcess.branch_name,
                  error: message,
                });
                retryFailureReason = `Unexpected error during merge retry: ${message.slice(0, 800)}`;
              } finally {
                await syncTaskStatusAfterMerge(store, tasks, toProcess.run_id, toProcess.task_id, projectPath, retryFailureReason, runLookup);
              }
            }
          }
        }
      }

      // ── Display results ─────────────────────────────────────────────

      if (merged.length > 0) {
        console.log(chalk.green.bold(`\nMerged ${merged.length} task(s):\n`));
        for (const m of merged) {
          console.log(`  ${chalk.cyan(m.taskId)} ${m.branchName}`);
        }
        console.log();
      }

      if (conflicts.length > 0) {
        console.log(chalk.yellow.bold(`Conflicts in ${conflicts.length} task(s):\n`));
        for (const c of conflicts) {
          console.log(`  ${chalk.cyan(c.taskId)} ${c.branchName}`);
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
          console.log(`  ${chalk.cyan(pr.taskId)} ${chalk.dim(pr.branchName)}`);
          console.log(`    ${chalk.underline(pr.prUrl)}`);
        }
        console.log();
      }

      if (testFailures.length > 0) {
        console.log(chalk.red.bold(`Test failures in ${testFailures.length} task(s):\n`));
        for (const f of testFailures) {
          console.log(`  ${chalk.cyan(f.taskId)} ${f.branchName}`);
          console.log(`    ${chalk.dim(f.error.split("\n")[0])}`);
        }
        console.log();
      }

      // Display running AI resolution rate after merge (MQ-T072)
      if (merged.length > 0 || conflicts.length > 0) {
        try {
          if (registered) return;
          const costTracker = new MergeCostTracker(store.getDb());
          const rate = await costTracker.getResolutionRate(30);
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
        if (taskFilter) {
          console.log(chalk.yellow(`No completed run found for task ${taskFilter}.`));
          console.log(chalk.dim("Use 'foreman merge --list' to see tasks ready to merge."));
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
