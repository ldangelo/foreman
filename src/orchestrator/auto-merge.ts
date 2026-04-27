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

import { execFileSync } from "node:child_process";
import { promisify } from "node:util";
import { join } from "node:path";
import { homedir } from "node:os";

import { loadProjectConfig, resolveVcsConfig } from "../lib/project-config.js";
import type { ForemanStore } from "../lib/store.js";
import type { ITaskClient } from "../lib/task-client.js";
import { VcsBackendFactory } from "../lib/vcs/index.js";
import type { VcsBackend } from "../lib/vcs/interface.js";
import { MergeQueue, RETRY_CONFIG } from "./merge-queue.js";
import { Refinery } from "./refinery.js";
import { PIPELINE_TIMEOUTS } from "../lib/config.js";
import { mapRunStatusToSeedStatus } from "../lib/run-status.js";
import { enqueueAddNotesToBead, enqueueMarkBeadFailed, enqueueSetBeadStatus } from "./task-backend-ops.js";

async function createAutoMergeVcsBackend(projectPath: string): Promise<VcsBackend> {
  const projectCfg = loadProjectConfig(projectPath);
  const vcsConfig = resolveVcsConfig(undefined, projectCfg?.vcs);
  return VcsBackendFactory.create(vcsConfig, projectPath);
}

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
 * When `failureReason` is provided (non-empty), adds it as a note on the bead
 * so that the bead record explains WHY it was blocked/failed. This is the
 * immediate fix described in the task: rather than waiting for
 * syncBeadStatusOnStartup() on the next restart, the bead is updated right
 * away with both status and context.
 *
 * Non-fatal — logs a warning on failure and lets the caller continue.
 */
export async function syncBeadStatusAfterMerge(
  store: ForemanStore,
  taskClient: ITaskClient,
  runId: string,
  seedId: string,
  projectPath: string,
  failureReason?: string,
): Promise<void> {
  const run = store.getRun(runId);
  if (!run) return;

  const expectedStatus = mapRunStatusToSeedStatus(run.status);
  // Enqueue the status update instead of calling br directly.
  // Multiple agent workers can trigger autoMerge concurrently after finalize,
  // and direct br calls contend on the beads SQLite database (SQLITE_BUSY).
  // The dispatcher's bead writer queue serializes all br operations.
  enqueueSetBeadStatus(store, seedId, expectedStatus, "auto-merge");

  // Add explanatory notes to the bead when there's a failure reason.
  // Done after the status update so that the status change is always attempted
  // even if the note fails. addNotesToBead() is itself non-fatal.
  if (failureReason) {
    enqueueAddNotesToBead(store, seedId, failureReason, "auto-merge");
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
  /**
   * Optional run ID for the immediate auto-merge case (agent-worker finalize).
   * When provided, this is passed to mergeCompleted's runId path, which fetches
   * the run directly by ID without status filtering. This is the most reliable
   * approach for immediate auto-merge calls where timing is critical.
   *
   * The runId should match the queue entry's run_id so mergeCompleted can locate
   * the run even if the status update hasn't been fully committed/visible yet.
   */
  runId?: string;
  /**
   * Optional pre-fetched run to bypass the getRun() query entirely.
   * When provided, this run is used directly instead of querying by runId.
   * This eliminates the race condition where the run status update hasn't been
   * committed/visible when autoMerge queries for the run by ID.
   */
  overrideRun?: import("../lib/store.js").Run;
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
  const { store, taskClient, projectPath, overrideRun, runId: optsRunId } = opts;
  const vcs = await createAutoMergeVcsBackend(projectPath);
  const targetBranch = opts.targetBranch ?? await vcs.detectDefaultBranch(projectPath);

  const project = store.getProjectByPath(projectPath);
  if (!project) {
    // No project registered — skip silently (init not run yet)
    return { merged: 0, conflicts: 0, failed: 0 };
  }

  const mq = new MergeQueue(store.getDb());
  const refinery = new Refinery(store, taskClient, projectPath, vcs);

  // Reconcile completed runs into the queue
  await mq.reconcile(store.getDb(), projectPath);

  let mergedCount = 0;
  let conflictCount = 0;
  let failedCount = 0;

  let entry = mq.dequeue();
  while (entry) {
    const currentEntry = entry;
    // Track the failure reason to attach as a bead note (if any failure occurs).
    // Declared outside try/catch so it's accessible in the finally block.
    let mergeFailureReason: string | undefined;
    // Track whether this queue entry resulted in a successful merge so that
    // bead-closed mail is only sent on actual success (Fix 2).
    let mergeSucceeded = false;

    // Determine merge intent from the queue entry first, falling back to the
    // run's merge_strategy for legacy queue rows that predate operation.
    const run = overrideRun?.id === currentEntry.run_id
      ? overrideRun
      : store.getRun(currentEntry.run_id);
    const mergeStrategy: 'auto' | 'pr' | 'none' = (run?.merge_strategy as 'auto' | 'pr' | 'none') ?? 'auto';
    const mergeOperation = currentEntry.operation
      ?? (mergeStrategy === 'pr' ? 'create_pr' : 'auto_merge');

    if (!currentEntry.operation && mergeStrategy === 'none') {
      // Skip merge entirely — mark as completed
      mq.updateStatus(currentEntry.id, 'merged', { completedAt: new Date().toISOString() });
      store.updateRun(currentEntry.run_id, { status: 'completed' });
      mergedCount += 1;
      mergeSucceeded = true;
      entry = mq.dequeue();
      continue;
    }

    if (mergeOperation === 'create_pr') {
      try {
        const pr = await refinery.ensurePullRequestForRun({
          runId: currentEntry.run_id,
          baseBranch: targetBranch,
          updateRunStatus: true,
          bodyNote: "Manual PR created by Foreman",
        });
        mq.updateStatus(currentEntry.id, 'merged', { completedAt: new Date().toISOString() });
        await syncBeadStatusAfterMerge(
          store,
          taskClient,
          currentEntry.run_id,
          currentEntry.seed_id,
          projectPath,
          `PR created for manual review.\nPR URL: ${pr.prUrl}`,
        );
        sendMail(store, currentEntry.run_id, "merge-conflict", {
          seedId: currentEntry.seed_id,
          branchName: pr.branchName,
          prUrl: pr.prUrl,
          prCreated: true,
        });
        conflictCount += 1;
        entry = mq.dequeue();
        continue;
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        mergeFailureReason = `Failed to create PR: ${message}`;
        mq.updateStatus(currentEntry.id, 'failed', { error: message });
        failedCount += 1;
        entry = mq.dequeue();
        continue;
      }
    }

    try {
      const effectiveRunId = optsRunId ?? overrideRun?.id ?? currentEntry.run_id;
      const report = typeof (refinery as Refinery & { mergePullRequest?: typeof refinery.mergePullRequest }).mergePullRequest === "function"
        ? await refinery.mergePullRequest({
          targetBranch,
          runId: effectiveRunId,
        })
        : await refinery.mergeCompleted({
          targetBranch,
          runTests: false,
          projectId: project.id,
          seedId: currentEntry.seed_id,
          runId: effectiveRunId,
          ...(overrideRun && overrideRun.id === currentEntry.run_id ? { overrideRun } : {}),
        });


      if (report.merged.length > 0) {
        mq.updateStatus(currentEntry.id, "merged", { completedAt: new Date().toISOString() });
        mergedCount += report.merged.length;
        mergeSucceeded = true;

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

        // Build failure reason for the bead note
        if (report.conflicts.length > 0) {
          const files = report.conflicts.flatMap((c) => c.conflictFiles).slice(0, 10);
          mergeFailureReason = `Merge conflict detected in branch foreman/${currentEntry.seed_id}.\nConflicting files:\n${files.map((f) => `  - ${f}`).join("\n") || "  (no file details available)"}`;
        }
        // Send merge-conflict mail for each conflicted run
        for (const conflictRun of report.conflicts) {
          sendMail(store, currentEntry.run_id, "merge-conflict", {
            seedId: conflictRun.seedId,
            branchName: conflictRun.branchName,
            conflictFiles: conflictRun.conflictFiles,
            prCreated: false,
          });
        }
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

        // Count repeated post-merge test failures for diagnostics. Retries are
        // now explicit/human-driven rather than automatic reopen-to-open.
        const testFailedRunsForSeed = store.getRunsByStatuses(["test-failed"], project.id)
          .filter((r: { seed_id: string }) => r.seed_id === currentEntry.seed_id);
        const totalTestFailCount = testFailedRunsForSeed.length;

        if (totalTestFailCount >= RETRY_CONFIG.maxRetries) {
          // Retry limit exhausted — permanently mark the bead as failed.
          enqueueMarkBeadFailed(store, currentEntry.seed_id, "auto-merge");
          mergeFailureReason = [
            `Post-merge tests failed ${totalTestFailCount} time(s) — retry limit (${RETRY_CONFIG.maxRetries}) exhausted.`,
            `Pre-existing failures on the dev branch may be causing false positives.`,
            `Manual investigation required. Use 'foreman retry ${currentEntry.seed_id}' after fixing dev-branch failures.`,
          ].join(" ");
          console.error(
            `[auto-merge] Seed ${currentEntry.seed_id} permanently failed after ${totalTestFailCount}` +
            ` test-failed attempts (limit: ${RETRY_CONFIG.maxRetries}). Preventing infinite re-dispatch.`,
          );
        } else {
          // Still below the retry limit, but require an explicit human retry.
          const firstFailure = report.testFailures[0];
          const errorSummary = firstFailure.error?.slice(0, 800) ?? "no details";
          mergeFailureReason = [
            `Post-merge tests failed (attempt ${totalTestFailCount}/${RETRY_CONFIG.maxRetries}).`,
            `Manual retry required after investigating the failure.`,
            `\nFirst failure:\n${errorSummary}`,
          ].join(" ");
        }

        // Send merge-failed mail for each test failure
        for (const failedRun of report.testFailures) {
          sendMail(store, currentEntry.run_id, "merge-failed", {
            seedId: failedRun.seedId,
            branchName: failedRun.branchName,
            reason: "test-failure",
            error: failedRun.error?.slice(0, 400),
            retryAttempt: totalTestFailCount,
            retryLimit: RETRY_CONFIG.maxRetries,
            retryExhausted: totalTestFailCount >= RETRY_CONFIG.maxRetries,
          });
        }
      } else if (report.unexpectedErrors && report.unexpectedErrors.length > 0) {
        const firstError = report.unexpectedErrors[0];
        mergeFailureReason = `PR merge failed: ${firstError.error.slice(0, 400)}`;
        mq.updateStatus(currentEntry.id, 'failed', { error: mergeFailureReason });
        failedCount += 1;
      } else {
        mq.updateStatus(currentEntry.id, "failed", { error: "No completed run found" });
        failedCount++;
        mergeFailureReason = `Merge failed: no mergeable run found for seed ${currentEntry.seed_id}. The run may have been deleted or not yet finalized.`;

        // Send merge-failed mail when no completed run was found in the queue
        sendMail(store, currentEntry.run_id, "merge-failed", {
          seedId: currentEntry.seed_id,
          reason: "no-completed-run",
        });
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      mergeFailureReason = `PR merge error: ${message.slice(0, 800)}`;
      mq.updateStatus(currentEntry.id, 'failed', { error: mergeFailureReason });
      failedCount += 1;

      sendMail(store, currentEntry.run_id, 'merge-failed', {
        seedId: currentEntry.seed_id,
        reason: 'unexpected-error',
        error: message.slice(0, 400),
      });
    } finally {
      // Sync bead status after every merge outcome (success or failure).
      // Pass mergeFailureReason so the bead gets a note explaining the failure.
      // Always runs — ensures br reflects the latest run status immediately.
      await syncBeadStatusAfterMerge(store, taskClient, currentEntry.run_id, currentEntry.seed_id, projectPath, mergeFailureReason);

      // Send bead-closed mail only when the merge actually succeeded.
      // Sending it on failure paths creates a misleading inbox entry where the
      // bead shows OPEN in br but "closed" in pipeline mail (Fix 2).
      if (mergeSucceeded) {
        sendMail(store, currentEntry.run_id, "bead-closed", {
          seedId: currentEntry.seed_id,
        });
      }
    }

    entry = mq.dequeue();
  }

  return { merged: mergedCount, conflicts: conflictCount, failed: failedCount };
}
