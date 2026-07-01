import { Command } from "commander";
import chalk from "chalk";

import { ForemanStore, type Run } from "../../lib/store.js";
import { PostgresStore } from "../../lib/postgres-store.js";
import { MergeQueue, type MergeQueueEntry } from "../../orchestrator/merge-queue.js";
import { PostgresMergeQueue } from "../../orchestrator/postgres-merge-queue.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import { archiveWorktreeReports } from "../../lib/archive-reports.js";
import { resolveProjectContext } from "./project-context.js";

type RunStore = ForemanStore | PostgresStore;

export interface AbandonOpts {
  reason?: string;
  dryRun?: boolean;
  deleteBranch?: boolean;
  force?: boolean;
  keepWorktree?: boolean;
  keepTask?: boolean;
  missingBranches?: boolean;
  project?: string;
  projectPath?: string;
}

function branchForSeed(seedId: string): string {
  return seedId.startsWith("foreman/") ? seedId : `foreman/${seedId}`;
}

async function getRun(store: RunStore, id: string): Promise<Run | null> {
  try {
    const direct = await Promise.resolve(store.getRun(id));
    if (direct) return direct;
  } catch {
    // Non-UUID task ids can make Postgres run lookup fail; fall back to seed lookup.
  }
  const runs = await Promise.resolve(store.getRunsForSeed(id));
  return runs[0] ?? null;
}

async function removeMergeQueueEntries(
  queue: MergeQueue | PostgresMergeQueue,
  run: Run,
  dryRun: boolean,
): Promise<number> {
  const branchName = branchForSeed(run.seed_id);
  const entries = await Promise.resolve(queue.list()) as MergeQueueEntry[];
  const matches = entries.filter((entry) =>
    entry.run_id === run.id || entry.seed_id === run.seed_id || entry.branch_name === branchName,
  );
  if (dryRun) return matches.length;
  for (const entry of matches) {
    await Promise.resolve(queue.remove(entry.id));
  }
  return matches.length;
}

async function abandonRun(
  run: Run,
  opts: AbandonOpts,
  deps: {
    projectPath: string;
    store: RunStore;
    queue: MergeQueue | PostgresMergeQueue;
    vcs: Awaited<ReturnType<typeof VcsBackendFactory.create>>;
  },
): Promise<void> {
  const dryRun = opts.dryRun ?? false;
  const reason = opts.reason ?? "abandoned by operator";
  const branchName = branchForSeed(run.seed_id);

  console.log(chalk.bold(`${dryRun ? "Would abandon" : "Abandoning"} ${chalk.cyan(run.seed_id)} (${run.id})`));
  console.log(`  reason: ${reason}`);

  const queueRemoved = await removeMergeQueueEntries(deps.queue, run, dryRun);
  console.log(`  ${dryRun ? "would remove" : "removed"} ${queueRemoved} merge queue entr${queueRemoved === 1 ? "y" : "ies"}`);

  if (!opts.keepWorktree && run.worktree_path) {
    if (dryRun) {
      console.log(`  would remove worktree ${chalk.dim(run.worktree_path)}`);
    } else {
      await archiveWorktreeReports(deps.projectPath, run.worktree_path, run.seed_id).catch(() => {});
      await deps.vcs.removeWorkspace(deps.projectPath, run.worktree_path);
      console.log(`  removed worktree ${chalk.dim(run.worktree_path)}`);
    }
  }

  if (opts.deleteBranch) {
    if (dryRun) {
      console.log(`  would delete branch ${chalk.dim(branchName)}${opts.force ? " (force)" : ""}`);
    } else {
      const result = await deps.vcs.deleteBranch(deps.projectPath, branchName, { force: opts.force });
      console.log(`  ${result.deleted ? "deleted" : "kept"} branch ${chalk.dim(branchName)}${result.wasFullyMerged ? " (merged)" : ""}`);
    }
  }

  if (!opts.keepTask && "updateTaskStatus" in deps.store) {
    if (dryRun) {
      console.log(`  would mark task ${chalk.dim(run.seed_id)} blocked`);
    } else {
      await Promise.resolve(deps.store.updateTaskStatus(run.seed_id, "blocked"));
      console.log(`  marked task ${chalk.dim(run.seed_id)} blocked`);
    }
  }

  if (!dryRun) {
    await Promise.resolve(deps.store.updateRun(run.id, { status: "failed", completed_at: new Date().toISOString() }));
    await Promise.resolve(deps.store.logEvent(run.project_id, "fail", {
      seedId: run.seed_id,
      reason,
      abandoned: true,
      branchName,
    }, run.id));
    console.log(`  marked run ${chalk.dim(run.id)} failed`);
  }
}

async function findCompletedRunsWithMissingBranches(store: RunStore, projectPath: string): Promise<Run[]> {
  const vcs = await VcsBackendFactory.create({ backend: "auto" }, projectPath);
  const completed = await Promise.resolve(store.getRunsByStatus("completed"));
  const branchExistsCache = new Map<string, boolean>();
  const missing: Run[] = [];
  for (const run of completed) {
    const branchName = branchForSeed(run.seed_id);
    let exists = branchExistsCache.get(branchName);
    if (exists === undefined) {
      exists = await vcs.branchExists(projectPath, branchName);
      branchExistsCache.set(branchName, exists);
    }
    if (!exists) missing.push(run);
  }
  return missing;
}

export async function abandonAction(target: string | undefined, opts: AbandonOpts = {}): Promise<number> {
  const { projectPath, registered } = await resolveProjectContext(opts, { normalizePaths: true });
  const localStore = ForemanStore.forProject(projectPath);
  const store: RunStore = registered ? PostgresStore.forProject(registered.id) : localStore;
  const close = () => {
    localStore.close();
    if (store !== localStore) store.close();
  };

  try {
    const queue = registered
      ? new PostgresMergeQueue(registered.id)
      : new MergeQueue(localStore.getDb());
    const vcs = await VcsBackendFactory.create({ backend: "auto" }, projectPath);
    const deps = { projectPath, store, queue, vcs };

    if (opts.missingBranches) {
      const runs = await findCompletedRunsWithMissingBranches(store, projectPath);
      if (runs.length === 0) {
        console.log(chalk.green("No completed runs with missing local branches found."));
        return 0;
      }
      console.log(chalk.bold(`${opts.dryRun ? "Would abandon" : "Abandoning"} ${runs.length} completed run(s) with missing local branches.`));
      for (const run of runs) {
        await abandonRun(run, opts, deps);
      }
      if (opts.dryRun) console.log(chalk.yellow("Dry run complete — no changes were made."));
      else console.log(chalk.green("Done."));
      return 0;
    }

    if (!target) {
      console.error(chalk.red("Error: provide <task-or-run-id> or use --missing-branches."));
      return 1;
    }
    const run = await getRun(store, target);
    if (!run) {
      console.error(chalk.red(`Error: No run or task found for '${target}'.`));
      return 1;
    }

    await abandonRun(run, opts, deps);
    if (opts.dryRun) console.log(chalk.yellow("Dry run complete — no changes were made."));
    else console.log(chalk.green("Done."));
    return 0;
  } finally {
    close();
  }
}

export const abandonCommand = new Command("abandon")
  .description("Abandon obsolete Foreman work: dequeue run, remove worktree, and mark task blocked")
  .argument("[task-or-run-id]", "Task/seed id or run id to abandon")
  .option("--missing-branches", "Bulk-abandon completed runs whose foreman/<task> branch is missing locally")
  .option("--reason <text>", "Reason recorded in run history")
  .option("--dry-run", "Preview changes without applying them")
  .option("--delete-branch", "Delete the foreman/<task> branch too")
  .option("--force", "Force branch deletion when used with --delete-branch")
  .option("--keep-worktree", "Do not remove the worktree")
  .option("--keep-task", "Do not mark the task blocked")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(async (target: string | undefined, opts: AbandonOpts) => {
    try {
      const code = await abandonAction(target, opts);
      if (code !== 0) process.exit(code);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${msg}`));
      process.exit(1);
    }
  });
