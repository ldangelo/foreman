import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { Command } from "commander";
import chalk from "chalk";

import { ForemanStore, type Run } from "../../lib/store.js";
import { PostgresStore } from "../../lib/postgres-store.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import { archiveWorktreeReports } from "../../lib/archive-reports.js";
import { MergeQueue, type MergeQueueEntry } from "../../orchestrator/merge-queue.js";
import { PostgresMergeQueue } from "../../orchestrator/postgres-merge-queue.js";
import { resolveProjectContext } from "./project-context.js";

const execFileAsync = promisify(execFile);

type RunStore = ForemanStore | PostgresStore;
type Queue = MergeQueue | PostgresMergeQueue;

export interface CleanStateOpts {
  dryRun?: boolean;
  force?: boolean;
  deleteBranches?: boolean;
  deleteOriginBranches?: boolean;
  keepTasks?: boolean;
  project?: string;
  projectPath?: string;
}

function branchForSeed(seedId: string): string {
  return seedId.startsWith("foreman/") ? seedId : `foreman/${seedId}`;
}

function seedFromBranch(branch: string): string {
  return branch.replace(/^foreman\//, "");
}

function isActiveRun(run: Run): boolean {
  return run.status === "pending" || run.status === "running";
}

function isDroppableRun(run: Run): boolean {
  return ["completed", "failed", "stuck", "conflict", "test-failed", "pr-created"].includes(run.status);
}

async function markRunDropped(store: RunStore, run: Run, reason: string, keepTasks: boolean): Promise<void> {
  await Promise.resolve(store.updateRun(run.id, {
    status: "failed",
    completed_at: new Date().toISOString(),
    merge_strategy: "none",
  }));
  await Promise.resolve(store.logEvent(run.project_id, "fail", {
    seedId: run.seed_id,
    reason,
    abandoned: true,
    cleanState: true,
    branchName: branchForSeed(run.seed_id),
  }, run.id));
  if (!keepTasks && "updateTaskStatus" in store) {
    await Promise.resolve(store.updateTaskStatus(run.seed_id, "blocked"));
  }
}

async function deleteOriginBranch(repoPath: string, branchName: string): Promise<void> {
  await execFileAsync("git", ["push", "origin", "--delete", branchName], { cwd: repoPath });
}

export async function cleanStateAction(opts: CleanStateOpts = {}): Promise<number> {
  const { projectPath, registered } = await resolveProjectContext(opts, { normalizePaths: true });
  const localStore = ForemanStore.forProject(projectPath);
  const store: RunStore = registered ? PostgresStore.forProject(registered.id) : localStore;
  const queue: Queue = registered ? new PostgresMergeQueue(registered.id) : new MergeQueue(localStore.getDb());
  const vcs = await VcsBackendFactory.create({ backend: "auto" }, projectPath);
  const dryRun = opts.dryRun ?? !opts.force;
  const reason = "clean state reset";

  const close = () => {
    localStore.close();
    if (store !== localStore) store.close();
  };

  try {
    if (!dryRun && !opts.force) {
      console.error(chalk.red("Error: clean-state mutation requires --force. Use --dry-run to preview."));
      return 1;
    }

    console.log(chalk.bold(`${dryRun ? "Would clean" : "Cleaning"} Foreman state for ${chalk.cyan(projectPath)}`));

    const entries = await Promise.resolve(queue.list()) as MergeQueueEntry[];
    const now = Date.now();
    const staleQueueEntries = entries.filter((entry) => {
      if (entry.status === "conflict" || entry.status === "failed") return true;
      if (entry.status === "pending" || entry.status === "merging") {
        const ts = new Date(entry.started_at ?? entry.enqueued_at).getTime();
        return Number.isFinite(ts) && now - ts > 60 * 60 * 1000;
      }
      return false;
    });

    const runsToDrop = new Map<string, Run>();
    const branchesToDelete = new Set<string>();
    for (const entry of staleQueueEntries) {
      branchesToDelete.add(branchForSeed(entry.seed_id));
      const run = await Promise.resolve(store.getRun(entry.run_id));
      if (run && isDroppableRun(run)) runsToDrop.set(run.id, run);
      const seedRuns = await Promise.resolve(store.getRunsForSeed(entry.seed_id));
      for (const seedRun of seedRuns) {
        if (isDroppableRun(seedRun)) runsToDrop.set(seedRun.id, seedRun);
      }
    }

    const workspaces = await vcs.listWorkspaces(projectPath);
    const foremanWorkspaces = workspaces.filter((wt) => wt.branch?.startsWith("foreman/"));
    const worktreesToRemove = new Map<string, { path: string; branch: string; seedId: string }>();

    for (const wt of foremanWorkspaces) {
      const seedId = seedFromBranch(wt.branch);
      const runs = await Promise.resolve(store.getRunsForSeed(seedId));
      const active = runs.some(isActiveRun);
      if (active) continue;
      const shouldDropRuns = runs.some(isDroppableRun);
      const orphan = runs.length === 0;
      if (shouldDropRuns || orphan) {
        worktreesToRemove.set(wt.path, { path: wt.path, branch: wt.branch, seedId });
        branchesToDelete.add(wt.branch);
        for (const run of runs) {
          if (isDroppableRun(run)) runsToDrop.set(run.id, run);
        }
      }
    }

    console.log(`  ${dryRun ? "would remove" : "removing"} ${staleQueueEntries.length} stale/conflict merge queue entr${staleQueueEntries.length === 1 ? "y" : "ies"}`);
    for (const run of runsToDrop.values()) branchesToDelete.add(branchForSeed(run.seed_id));

    console.log(`  ${dryRun ? "would mark" : "marking"} ${runsToDrop.size} run(s) abandoned`);
    console.log(`  ${dryRun ? "would remove" : "removing"} ${worktreesToRemove.size} foreman worktree(s)`);
    if (opts.deleteBranches) console.log(`  ${dryRun ? "would delete" : "deleting"} ${branchesToDelete.size} local branch(es)`);
    if (opts.deleteOriginBranches) console.log(`  ${dryRun ? "would delete" : "deleting"} ${branchesToDelete.size} origin branch(es)`);

    if (dryRun) {
      for (const entry of staleQueueEntries) console.log(`  queue: ${entry.seed_id} (${entry.status})`);
      for (const run of runsToDrop.values()) console.log(`  run: ${run.seed_id} (${run.status}) ${run.id}`);
      for (const wt of worktreesToRemove.values()) console.log(`  worktree: ${wt.seedId} ${wt.path}`);
      console.log(chalk.yellow("Dry run complete — no changes were made. Re-run with --force to apply."));
      return 0;
    }

    for (const entry of staleQueueEntries) {
      await Promise.resolve(queue.remove(entry.id));
    }
    for (const run of runsToDrop.values()) {
      await markRunDropped(store, run, reason, opts.keepTasks ?? false);
    }
    for (const wt of worktreesToRemove.values()) {
      await archiveWorktreeReports(projectPath, wt.path, wt.seedId).catch(() => {});
      await vcs.removeWorkspace(projectPath, wt.path);
    }
    if (opts.deleteBranches) {
      for (const branchName of branchesToDelete) {
        await vcs.deleteBranch(projectPath, branchName, { force: true }).catch(() => ({ deleted: false, wasFullyMerged: false }));
      }
    }
    if (opts.deleteOriginBranches) {
      for (const branchName of branchesToDelete) {
        await deleteOriginBranch(projectPath, branchName).catch(() => undefined);
      }
    }

    console.log(chalk.green("Done."));
    return 0;
  } finally {
    close();
  }
}

export const cleanStateCommand = new Command("clean-state")
  .description("Reset Foreman to a clean operator state by dropping stale/obsolete work")
  .option("--dry-run", "Preview changes without applying them")
  .option("--force", "Apply the cleanup")
  .option("--delete-branches", "Delete associated local foreman/* branches")
  .option("--delete-origin-branches", "Also delete associated origin foreman/* branches")
  .option("--keep-tasks", "Do not mark related tasks blocked")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(async (opts: CleanStateOpts) => {
    try {
      const code = await cleanStateAction(opts);
      if (code !== 0) process.exit(code);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(chalk.red(`Error: ${msg}`));
      process.exit(1);
    }
  });
