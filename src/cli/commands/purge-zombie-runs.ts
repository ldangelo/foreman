import chalk from "chalk";

import { createTaskClient } from "../../lib/task-client-factory.js";
import { ForemanStore, type Run } from "../../lib/store.js";
import { ElixirCliStore } from "./elixir-cli-store.js";
import type { ITaskClient } from "../../lib/task-client.js";
import { resolveRepoRootProjectPath } from "./project-task-support.js";
import { findRegisteredProjectByPath } from "./project-context.js";
import { closeStoreIfPossible, wrapLocalRunStore } from "./local-store-adapter.js";
import { printDryRunNotice, printPurgeSummary } from "./cli-output.js";

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

// ── Core action (exported for testing) ───────────────────────────────

/**
 * Check whether a task is closed (or no longer exists).
 * Returns true if the run should be purged.
 */
async function isTaskClosedOrGone(
  tasksClient: Pick<ITaskClient, "show">,
  taskId: string,
): Promise<boolean> {
  try {
    const task = await tasksClient.show(taskId);
    return task.status === "closed" || task.status === "completed";
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
  tasksClient: Pick<ITaskClient, "show">,
  store: PurgeZombieStore,
  projectPath: string,
): Promise<PurgeZombieRunsResult> {
  const dryRun = opts.dryRun ?? false;

  printDryRunNotice(dryRun);

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

  // 3. Check each failed run's task and purge if the task is closed / gone
  for (const run of failedRuns) {
    let shouldPurge: boolean;
    try {
      shouldPurge = await isTaskClosedOrGone(tasksClient, run.task_id);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.warn(
        chalk.yellow(`  warn  run ${run.id} (task ${run.task_id}): ${msg} — skipping`),
      );
      result.errors += 1;
      continue;
    }

    if (!shouldPurge) {
      console.log(
        chalk.dim(`  skip  run ${run.id} — task ${run.task_id} is still open`),
      );
      result.skipped += 1;
      continue;
    }

    if (dryRun) {
      console.log(
        chalk.cyan(`  would purge  run ${run.id} — task ${run.task_id} is closed/gone`),
      );
      result.purged += 1;
    } else {
      await store.deleteRun(run.id);
      console.log(
        chalk.green(`  purged  run ${run.id} — task ${run.task_id} is closed/gone`),
      );
      result.purged += 1;
    }
  }

  // 4. Summary
  printPurgeSummary({
    dryRun,
    subject: "zombie run(s)",
    verb: "purged",
    count: result.purged,
    skipped: result.skipped,
    errors: result.errors,
  });

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
  const registered = await findRegisteredProjectByPath(projectPath);
  const store: PurgeZombieStore = registered
    ? ElixirCliStore.forProject(registered)
    : wrapLocalRunStore(localStore);
  const { taskClient } = await createTaskClient(projectPath);

  try {
    const result = await purgeZombieRunsAction(opts, taskClient, store, projectPath);
    localStore.close();
    closeStoreIfPossible(store);
    return result.errors > 0 ? 1 : 0;
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(chalk.red(msg));
    localStore.close();
    closeStoreIfPossible(store);
    return 1;
  }
}

// The CLI command surface lives in purge.ts:
//   foreman purge runs           (canonical)
//   foreman purge-zombie-runs    (hidden, deprecated alias)
