import { Command } from "commander";
import chalk from "chalk";

import { ForemanStore } from "../../lib/store.js";
import { PostgresStore } from "../../lib/postgres-store.js";
import type { Run } from "../../lib/store.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import type { Workspace } from "../../lib/vcs/types.js";
import { archiveWorktreeReports } from "../../lib/archive-reports.js";
import { ensureCliPostgresPool, listRegisteredProjects, resolveRepoRootProjectPath } from "./project-task-support.js";

// ── Types ─────────────────────────────────────────────────────────────────────

export interface WorktreeInfo {
  path: string;
  branch: string;
  head: string;
  seedId: string;
  runStatus: Run["status"] | null;
  runId: string | null;
  createdAt: string | null;
}

export interface CleanResult {
  removed: number;
  errors: string[];
  /** Populated in dry-run mode: the worktrees that would have been removed. */
  wouldRemove?: WorktreeInfo[];
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/** Statuses considered terminal/cleanable without --all. */
const CLEANABLE_STATUSES = new Set<string>([
  "completed",
  "merged",
  "failed",
  "test-failed",
  "conflict",
  "pr-created",
]);

/**
 * Extract seed ID from a foreman branch name.
 * "foreman/seed-abc" -> "seed-abc"
 */
function seedIdFromBranch(branch: string): string {
  return branch.replace(/^foreman\//, "");
}

// ── Core logic (exported for testing) ─────────────────────────────────────────

/**
 * List all foreman/* worktrees with metadata from the store.
 */
export async function listForemanWorktrees(
  projectPath: string,
  store: Pick<PostgresStore, "getRunsForSeed"> | Pick<ForemanStore, "getRunsForSeed">,
): Promise<WorktreeInfo[]> {
  const vcs = await VcsBackendFactory.create({ backend: "auto" }, projectPath);
  const worktrees = await vcs.listWorkspaces(projectPath);

  const foremanWorktrees = worktrees.filter((wt) =>
    wt.branch.startsWith("foreman/"),
  );

  const results: WorktreeInfo[] = [];
  for (const wt of foremanWorktrees) {
    const seedId = seedIdFromBranch(wt.branch);
    const runs = await store.getRunsForSeed(seedId);
    const latestRun = runs.length > 0 ? runs[0] : null;

    results.push({
      path: wt.path,
      branch: wt.branch,
      head: wt.head,
      seedId,
      runStatus: latestRun?.status ?? null,
      runId: latestRun?.id ?? null,
      createdAt: latestRun?.created_at ?? null,
    });
  }
  return results;
}

/**
 * Clean worktrees based on their run status.
 * - Default: only remove worktrees for completed/merged/failed runs.
 * - `all: true`: remove all foreman worktrees.
 * - `force: true`: use force branch deletion.
 * - `dryRun: true`: show what would be removed without making changes.
 */
export async function cleanWorktrees(
  projectPath: string,
  worktrees: WorktreeInfo[],
  opts: { all: boolean; force: boolean; dryRun?: boolean },
): Promise<CleanResult> {
  let removed = 0;
  const errors: string[] = [];
  const wouldRemove: WorktreeInfo[] = [];

  for (const wt of worktrees) {
    const shouldClean =
      opts.all ||
      wt.runStatus === null ||
      CLEANABLE_STATUSES.has(wt.runStatus);

    if (!shouldClean) continue;

    if (opts.dryRun) {
      removed++;
      wouldRemove.push(wt);
      continue;
    }

    try {
      await archiveWorktreeReports(projectPath, wt.path, wt.seedId);
      const vcs = await VcsBackendFactory.create({ backend: "auto" }, projectPath);
      await vcs.removeWorkspace(projectPath, wt.path);
      await vcs.deleteBranch(projectPath, wt.branch, {
        force: opts.force,
      });
      removed++;
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      errors.push(`${wt.seedId}: ${msg}`);
    }
  }

  return { removed, errors, ...(opts.dryRun ? { wouldRemove } : {}) };
}

// ── CLI command ───────────────────────────────────────────────────────────────

export interface WorktreeListOpts {
  json?: boolean;
}

export interface WorktreeCleanOpts {
  all?: boolean;
  force?: boolean;
  dryRun?: boolean;
}

function closeWorktreeStores(
  localStore: ForemanStore,
  store: Pick<ForemanStore, "close"> | Pick<PostgresStore, "close">,
): void {
  localStore.close();
  if ("close" in store && typeof store.close === "function") {
    store.close();
  }
}

export async function worktreeListCommandAction(opts: WorktreeListOpts): Promise<void> {
  try {
    const projectPath = await resolveRepoRootProjectPath({});
    const registered = (await listRegisteredProjects()).find((project) => project.path === projectPath);
    if (registered) {
      ensureCliPostgresPool(projectPath);
    }
    const localStore = ForemanStore.forProject(projectPath);
    const store = registered ? PostgresStore.forProject(registered.id) : localStore;

    const worktrees = await listForemanWorktrees(projectPath, store);

    if (opts.json) {
      console.log(JSON.stringify(worktrees, null, 2));
      closeWorktreeStores(localStore, store);
      return;
    }

    if (worktrees.length === 0) {
      console.log(chalk.yellow("No foreman worktrees found."));
      closeWorktreeStores(localStore, store);
      return;
    }

    console.log(chalk.bold(`Foreman worktrees (${worktrees.length}):\n`));

    for (const wt of worktrees) {
      const age = wt.createdAt
        ? `${Math.round((Date.now() - new Date(wt.createdAt).getTime()) / 60000)}m ago`
        : "unknown";
      const status = wt.runStatus
        ? formatStatus(wt.runStatus)
        : chalk.dim("no run");

      console.log(
        `  ${chalk.cyan(wt.seedId)} ${status} ${chalk.dim(wt.path)} ${chalk.dim(`(${age})`)}`,
      );
    }

    closeWorktreeStores(localStore, store);
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(chalk.red(`Error: ${message}`));
    process.exit(1);
  }
}

export async function worktreeCleanCommandAction(opts: WorktreeCleanOpts): Promise<void> {
  try {
    const projectPath = await resolveRepoRootProjectPath({});
    const registered = (await listRegisteredProjects()).find((project) => project.path === projectPath);
    if (registered) {
      ensureCliPostgresPool(projectPath);
    }
    const localStore = ForemanStore.forProject(projectPath);
    const store = registered ? PostgresStore.forProject(registered.id) : localStore;
    const dryRun = opts.dryRun ?? false;

    const worktrees = await listForemanWorktrees(projectPath, store);

    if (worktrees.length === 0) {
      console.log(chalk.yellow("No foreman worktrees to clean."));
      closeWorktreeStores(localStore, store);
      return;
    }

    if (dryRun) {
      console.log(chalk.dim("(dry-run mode — no changes will be made)\n"));
    }

    console.log(chalk.bold("Cleaning foreman worktrees...\n"));

    const result = await cleanWorktrees(projectPath, worktrees, {
      all: Boolean(opts.all),
      force: Boolean(opts.force),
      dryRun,
    });

    if (dryRun && result.wouldRemove && result.wouldRemove.length > 0) {
      console.log(chalk.dim("Worktrees that would be removed:"));
      for (const wt of result.wouldRemove) {
        console.log(`  ${chalk.cyan(wt.seedId)}  ${chalk.dim(wt.path)}`);
      }
    }

    const action = dryRun ? "Would remove" : "Removed";
    console.log(chalk.green.bold(`\n${action} ${result.removed} worktree(s).`));

    if (result.errors.length > 0) {
      console.log(chalk.red(`\nErrors (${result.errors.length}):`));
      for (const err of result.errors) {
        console.log(chalk.red(`  ${err}`));
      }
    }

    closeWorktreeStores(localStore, store);
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(chalk.red(`Error: ${message}`));
    process.exit(1);
  }
}

const listSubcommand = new Command("list")
  .description("List all foreman worktrees")
  .option("--json", "Output as JSON")
  .action(worktreeListCommandAction);

const cleanSubcommand = new Command("clean")
  .description("Remove worktrees for completed/merged/failed runs")
  .option("--all", "Remove all foreman worktrees including active ones")
  .option("--force", "Force-delete branches even if not fully merged")
  .option("--dry-run", "Show what would be removed without making changes")
  .action(worktreeCleanCommandAction);

export const worktreeCommand = new Command("worktree")
  .description("Manage foreman worktrees")
  .addCommand(listSubcommand)
  .addCommand(cleanSubcommand);

// ── Format helpers ────────────────────────────────────────────────────────────

function formatStatus(status: string): string {
  switch (status) {
    case "running":
    case "pending":
      return chalk.blue(status);
    case "completed":
      return chalk.green(status);
    case "merged":
      return chalk.green(status);
    case "failed":
    case "stuck":
    case "test-failed":
    case "conflict":
      return chalk.red(status);
    case "pr-created":
      return chalk.cyan(status);
    default:
      return chalk.dim(status);
  }
}
