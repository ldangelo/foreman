import { Command } from "commander";
import chalk from "chalk";

import { createTaskClient } from "../../lib/task-client-factory.js";
import { ForemanStore, type Run } from "../../lib/store.js";
import { PostgresStore } from "../../lib/postgres-store.js";
import type { ITaskClient } from "../../lib/task-client.js";
import {
  ensureCliPostgresPool,
  listRegisteredProjects,
  resolveRepoRootProjectPath,
} from "./project-task-support.js";

// ── Types ─────────────────────────────────────────────────────────────

export interface PurgeZombieRunsOpts {
  dryRun?: boolean;
}

export interface PurgeZombieRunsResult {
  checked: number;
  purged: number;
  skipped: number;
  errors: number;
}

interface PurgeZombieStore {
  getProjectByPath(path: string): Promise<{ id: string; path: string } | null>;
  getRunsByStatus(status: Run["status"], projectId: string): Promise<Run[]>;
  deleteRun(runId: string): Promise<boolean>;
}

function wrapLocalPurgeZombieStore(store: ForemanStore): PurgeZombieStore {
  return {
    getProjectByPath: async (path) => store.getProjectByPath(path),
    getRunsByStatus: async (status, projectId) => store.getRunsByStatus(status, projectId),
    deleteRun: async (runId) => store.deleteRun(runId),
  };
}

// ── Core action (exported for testing) ───────────────────────────────

/**
 * Check whether a bead is closed (or no longer exists).
 * Returns true if the run should be purged.
 */
async function isBeadClosedOrGone(
  beadsClient: Pick<ITaskClient, "show">,
  seedId: string,
): Promise<boolean> {
  try {
    const bead = await beadsClient.show(seedId);
    return bead.status === "closed" || bead.status === "completed";
  } catch (err: unknown) {
    const msg = (err instanceof Error ? err.message : String(err)).toLowerCase();
    // Treat a 404 / not-found as "gone" — safe to purge
    if (msg.includes("404") || msg.includes("not found") || msg.includes("no issue")) {
      return true;
    }
    // Re-throw unexpected errors so callers can count them
    throw err;
  }
}

/**
 * Core purge logic extracted for testability.
 * Returns a summary result object.
 */
export async function purgeZombieRunsAction(
  opts: PurgeZombieRunsOpts,
  beadsClient: Pick<ITaskClient, "show">,
  store: PurgeZombieStore,
  projectPath: string,
): Promise<PurgeZombieRunsResult> {
  const dryRun = opts.dryRun ?? false;

  if (dryRun) {
    console.log(chalk.yellow("(dry run — no changes will be made)\n"));
  }

  // 1. Validate project exists
  const project = await store.getProjectByPath(projectPath);
  if (!project) {
    throw new Error("No project registered for this path. Run 'foreman init' first.");
  }

  // 2. Get all failed runs for this project
  const failedRuns: Run[] = await store.getRunsByStatus("failed", project.id);

  if (failedRuns.length === 0) {
    console.log(chalk.green("No failed runs found — nothing to purge."));
    return { checked: 0, purged: 0, skipped: 0, errors: 0 };
  }

  console.log(
    chalk.bold(`Checking ${failedRuns.length} failed run(s) for zombie records…\n`),
  );

  const result: PurgeZombieRunsResult = {
    checked: failedRuns.length,
    purged: 0,
    skipped: 0,
    errors: 0,
  };

  // 3. Check each failed run's bead and purge if the bead is closed / gone
  for (const run of failedRuns) {
    let shouldPurge: boolean;
    try {
      shouldPurge = await isBeadClosedOrGone(beadsClient, run.seed_id);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.warn(
        chalk.yellow(`  warn  run ${run.id} (bead ${run.seed_id}): ${msg} — skipping`),
      );
      result.errors += 1;
      continue;
    }

    if (!shouldPurge) {
      console.log(
        chalk.dim(`  skip  run ${run.id} — bead ${run.seed_id} is still open`),
      );
      result.skipped += 1;
      continue;
    }

    if (dryRun) {
      console.log(
        chalk.cyan(`  would purge  run ${run.id} — bead ${run.seed_id} is closed/gone`),
      );
      result.purged += 1;
    } else {
      await store.deleteRun(run.id);
      console.log(
        chalk.green(`  purged  run ${run.id} — bead ${run.seed_id} is closed/gone`),
      );
      result.purged += 1;
    }
  }

  // 4. Summary
  console.log();
  if (dryRun) {
    console.log(
      chalk.yellow(
        `Dry run complete — ${result.purged} zombie run(s) would be purged, ${result.skipped} skipped, ${result.errors} error(s).`,
      ),
    );
  } else {
    console.log(
      chalk.green(
        `Done — ${result.purged} zombie run(s) purged, ${result.skipped} skipped, ${result.errors} error(s).`,
      ),
    );
  }

  return result;
}

export async function purgeZombieRunsCommandAction(opts: PurgeZombieRunsOpts): Promise<number> {
  let projectPath: string;
  try {
    projectPath = await resolveRepoRootProjectPath({});
  } catch {
    console.error(chalk.red("Not in a git repository. Run from within a foreman project."));
    return 1;
  }

  const localStore = ForemanStore.forProject(projectPath);
  const registered = (await listRegisteredProjects()).find((project) => project.path === projectPath);
  if (registered) {
    ensureCliPostgresPool(projectPath);
  }
  const store: PurgeZombieStore = registered
    ? PostgresStore.forProject(registered.id)
    : wrapLocalPurgeZombieStore(localStore);
  const { taskClient } = await createTaskClient(projectPath);

  try {
    const result = await purgeZombieRunsAction(opts, taskClient, store, projectPath);
    localStore.close();
    if ("close" in store && typeof (store as { close?: () => void }).close === "function") {
      (store as { close: () => void }).close();
    }
    return result.errors > 0 ? 1 : 0;
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(chalk.red(msg));
    localStore.close();
    if ("close" in store && typeof (store as { close?: () => void }).close === "function") {
      (store as { close: () => void }).close();
    }
    return 1;
  }
}

// ── CLI Command ─────────────────────────────────────────────────────────

export const purgeZombieRunsCommand = new Command("purge-zombie-runs")
  .description(
    "Remove failed run records whose beads are already closed or no longer exist",
  )
  .option("--dry-run", "Show what would be purged without making any changes")
  .action(async (opts: PurgeZombieRunsOpts) => {
    process.exit(await purgeZombieRunsCommandAction(opts));
  });
