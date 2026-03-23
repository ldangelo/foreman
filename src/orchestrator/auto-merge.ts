/**
 * auto-merge.ts — Standalone autoMerge function and supporting helpers.
 *
 * Extracted from src/cli/commands/run.ts so that both the `foreman run`
 * dispatch loop AND the agent-worker's onPipelineComplete callback can
 * trigger merge queue draining without creating circular module dependencies.
 *
 * The key design goal: when an agent completes its pipeline (finalize phase
 * succeeds), it should immediately drain the merge queue rather than waiting
 * for `foreman run` to be running and call autoMerge() in its dispatch loop.
 */

import { execFile, execFileSync } from "node:child_process";
import { promisify } from "node:util";
import { join } from "node:path";
import { homedir } from "node:os";

import type { ForemanStore } from "../lib/store.js";
import type { ITaskClient } from "../lib/task-client.js";
import { detectDefaultBranch } from "../lib/git.js";
import { MergeQueue } from "./merge-queue.js";
import { Refinery } from "./refinery.js";
import { PIPELINE_TIMEOUTS } from "../lib/config.js";
import { mapRunStatusToSeedStatus } from "../lib/run-status.js";

const execFileAsync = promisify(execFile);

// ── Helpers ──────────────────────────────────────────────────────────────────

/** Absolute path to the br binary. */
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
export async function syncBeadStatusAfterMerge(
  store: ForemanStore,
  taskClient: ITaskClient,
  runId: string,
  seedId: string,
  projectPath: string,
): Promise<void> {
  const run = store.getRun(runId);
  if (!run) return;

  const expectedStatus = mapRunStatusToSeedStatus(run.status);
  try {
    await taskClient.update(seedId, { status: expectedStatus });
    execFileSync(brPath(), ["sync", "--flush-only"], {
      stdio: "pipe",
      timeout: PIPELINE_TIMEOUTS.beadClosureMs,
      cwd: projectPath,
    });
  } catch (syncErr: unknown) {
    const msg = syncErr instanceof Error ? syncErr.message : String(syncErr);
    console.warn(`[merge] Warning: Failed to sync bead status for ${seedId}: ${msg}`);
  }
}

// ── Auto-Merge ───────────────────────────────────────────────────────────────

/** Options for the autoMerge function. */
export interface AutoMergeOpts {
  store: ForemanStore;
  taskClient: ITaskClient;
  projectPath: string;
  /** Merge target branch. When omitted, auto-detected via detectDefaultBranch(). */
  targetBranch?: string;
}

/** Result summary returned by autoMerge(). */
export interface AutoMergeResult {
  merged: number;
  conflicts: number;
  failed: number;
}

/**
 * Process the merge queue: reconcile completed runs, then drain pending entries
 * via the Refinery.
 *
 * Non-fatal — errors are logged and the caller continues. Returns a summary of
 * what happened (for logging / testing).
 *
 * This function is called from two places:
 *  1. `foreman run` dispatch loop — between agent batches (existing behaviour)
 *  2. `agent-worker` onPipelineComplete callback — immediately after finalize
 *     succeeds (new behaviour, fixes the "foreman run exits early" bug)
 */
export async function autoMerge(opts: AutoMergeOpts): Promise<AutoMergeResult> {
  const { store, taskClient, projectPath } = opts;
  const targetBranch = opts.targetBranch ?? await detectDefaultBranch(projectPath);

  const project = store.getProjectByPath(projectPath);
  if (!project) {
    // No project registered — skip silently (init not run yet)
    return { merged: 0, conflicts: 0, failed: 0 };
  }

  const mq = new MergeQueue(store.getDb());
  const refinery = new Refinery(store, taskClient, projectPath);

  // Reconcile completed runs into the queue
  await mq.reconcile(store.getDb(), projectPath, execFileAsync);

  let mergedCount = 0;
  let conflictCount = 0;
  let failedCount = 0;

  let entry = mq.dequeue();
  while (entry) {
    const currentEntry = entry;
    try {
      const report = await refinery.mergeCompleted({
        targetBranch,
        runTests: true,
        testCommand: "npm test",
        projectId: project.id,
        seedId: currentEntry.seed_id,
      });

      if (report.merged.length > 0) {
        mq.updateStatus(currentEntry.id, "merged", { completedAt: new Date().toISOString() });
        mergedCount += report.merged.length;
      } else if (report.conflicts.length > 0 || report.prsCreated.length > 0) {
        mq.updateStatus(currentEntry.id, "conflict", { error: "Code conflicts" });
        conflictCount += report.conflicts.length + report.prsCreated.length;
      } else if (report.testFailures.length > 0) {
        mq.updateStatus(currentEntry.id, "failed", { error: "Test failures" });
        failedCount += report.testFailures.length;
      } else {
        mq.updateStatus(currentEntry.id, "failed", { error: "No completed run found" });
        failedCount++;
      }

      // Immediately sync bead status in br so it reflects the merge outcome
      // without waiting for the next foreman startup reconciliation.
      await syncBeadStatusAfterMerge(store, taskClient, currentEntry.run_id, currentEntry.seed_id, projectPath);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      mq.updateStatus(currentEntry.id, "failed", { error: message });
      failedCount++;
      // Sync bead status even when refinery throws (run may have been updated before exception)
      await syncBeadStatusAfterMerge(store, taskClient, currentEntry.run_id, currentEntry.seed_id, projectPath);
    }

    entry = mq.dequeue();
  }

  return { merged: mergedCount, conflicts: conflictCount, failed: failedCount };
}
