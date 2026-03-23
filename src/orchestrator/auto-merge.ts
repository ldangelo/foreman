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
 * Fire-and-forget helper to send a mail message via the store.
 * Uses store.sendMessage() directly — same pattern as Refinery.sendMail().
 * Never throws — failures are silently ignored (mail is optional infrastructure).
 */
function sendMail(
  store: ForemanStore,
  runId: string,
  subject: string,
  body: Record<string, unknown>,
): void {
  try {
    store.sendMessage(runId, "auto-merge", "foreman", subject, JSON.stringify({
      ...body,
      timestamp: new Date().toISOString(),
    }));
  } catch {
    // Non-fatal — mail is optional infrastructure
  }
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
 * Sends mail notifications for each merge outcome so that `foreman inbox` shows
 * the full lifecycle from dispatch through merge:
 *   - merge-complete  — branch merged successfully, bead closed
 *   - merge-conflict  — conflict detected, PR created or manual intervention needed
 *   - merge-failed    — merge failed (test failures, no completed run, or unexpected error)
 *   - bead-closed     — bead status synced in br after merge outcome
 *
 * Note: Refinery also sends per-run merge lifecycle messages. autoMerge sends
 * wrapper-level messages from sender "auto-merge" to provide queue-level context.
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

        // Send merge-complete mail for each successfully merged run
        for (const mergedRun of report.merged) {
          sendMail(store, currentEntry.run_id, "merge-complete", {
            seedId: mergedRun.seedId,
            branchName: mergedRun.branchName,
            targetBranch,
          });
        }
      } else if (report.conflicts.length > 0 || report.prsCreated.length > 0) {
        mq.updateStatus(currentEntry.id, "conflict", { error: "Code conflicts" });
        conflictCount += report.conflicts.length + report.prsCreated.length;

        // Send merge-conflict mail for each conflicted run
        for (const conflictRun of report.conflicts) {
          sendMail(store, currentEntry.run_id, "merge-conflict", {
            seedId: conflictRun.seedId,
            branchName: conflictRun.branchName,
            conflictFiles: conflictRun.conflictFiles,
            prCreated: false,
          });
        }
        // Send merge-conflict mail for PRs created on conflict
        for (const pr of report.prsCreated) {
          sendMail(store, currentEntry.run_id, "merge-conflict", {
            seedId: pr.seedId,
            branchName: pr.branchName,
            prUrl: pr.prUrl,
            prCreated: true,
          });
        }
      } else if (report.testFailures.length > 0) {
        mq.updateStatus(currentEntry.id, "failed", { error: "Test failures" });
        failedCount += report.testFailures.length;

        // Send merge-failed mail for each test failure
        for (const failedRun of report.testFailures) {
          sendMail(store, currentEntry.run_id, "merge-failed", {
            seedId: failedRun.seedId,
            branchName: failedRun.branchName,
            reason: "test-failure",
            error: failedRun.error?.slice(0, 400),
          });
        }
      } else {
        mq.updateStatus(currentEntry.id, "failed", { error: "No completed run found" });
        failedCount++;

        // Send merge-failed mail when no completed run was found in the queue
        sendMail(store, currentEntry.run_id, "merge-failed", {
          seedId: currentEntry.seed_id,
          reason: "no-completed-run",
        });
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      mq.updateStatus(currentEntry.id, "failed", { error: message });
      failedCount++;

      // Send merge-failed mail when an unexpected error occurs in the merge pipeline
      sendMail(store, currentEntry.run_id, "merge-failed", {
        seedId: currentEntry.seed_id,
        reason: "unexpected-error",
        error: message.slice(0, 400),
      });
    } finally {
      // Sync bead status after every merge outcome (success or failure).
      // Always runs — ensures br reflects the latest run status.
      await syncBeadStatusAfterMerge(store, taskClient, currentEntry.run_id, currentEntry.seed_id, projectPath);

      // Send bead-closed mail after bead status is synced.
      // Always sent so inbox shows lifecycle completion for every queue entry.
      sendMail(store, currentEntry.run_id, "bead-closed", {
        seedId: currentEntry.seed_id,
      });
    }

    entry = mq.dequeue();
  }

  return { merged: mergedCount, conflicts: conflictCount, failed: failedCount };
}
