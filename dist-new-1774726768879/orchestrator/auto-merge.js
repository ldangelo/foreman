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
import { detectDefaultBranch } from "../lib/git.js";
import { MergeQueue, RETRY_CONFIG } from "./merge-queue.js";
import { Refinery } from "./refinery.js";
import { PIPELINE_TIMEOUTS } from "../lib/config.js";
import { mapRunStatusToSeedStatus } from "../lib/run-status.js";
import { enqueueAddNotesToBead, enqueueMarkBeadFailed } from "./task-backend-ops.js";
const execFileAsync = promisify(execFile);
// ── Helpers ──────────────────────────────────────────────────────────────────
/** Absolute path to the br binary. */
function brPath() {
    return join(homedir(), ".local", "bin", "br");
}
/**
 * Fire-and-forget helper to send a mail message via the store.
 * Uses store.sendMessage() directly — same pattern as Refinery.sendMail().
 * Never throws — failures are silently ignored (mail is optional infrastructure).
 */
function sendMail(store, runId, subject, body) {
    try {
        store.sendMessage(runId, "auto-merge", "foreman", subject, JSON.stringify({
            ...body,
            timestamp: new Date().toISOString(),
        }));
    }
    catch {
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
export async function syncBeadStatusAfterMerge(store, taskClient, runId, seedId, projectPath, failureReason) {
    const run = store.getRun(runId);
    if (!run)
        return;
    const expectedStatus = mapRunStatusToSeedStatus(run.status);
    try {
        await taskClient.update(seedId, { status: expectedStatus });
        execFileSync(brPath(), ["sync", "--flush-only"], {
            stdio: "pipe",
            timeout: PIPELINE_TIMEOUTS.beadClosureMs,
            cwd: projectPath,
        });
    }
    catch (syncErr) {
        const msg = syncErr instanceof Error ? syncErr.message : String(syncErr);
        console.warn(`[merge] Warning: Failed to sync bead status for ${seedId}: ${msg}`);
    }
    // Add explanatory notes to the bead when there's a failure reason.
    // Done after the status update so that the status change is always attempted
    // even if the note fails. addNotesToBead() is itself non-fatal.
    if (failureReason) {
        enqueueAddNotesToBead(store, seedId, failureReason, "auto-merge");
    }
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
export async function autoMerge(opts) {
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
        // Track the failure reason to attach as a bead note (if any failure occurs).
        // Declared outside try/catch so it's accessible in the finally block.
        let mergeFailureReason;
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
            }
            else if (report.conflicts.length > 0 || report.prsCreated.length > 0) {
                mq.updateStatus(currentEntry.id, "conflict", { error: "Code conflicts" });
                conflictCount += report.conflicts.length + report.prsCreated.length;
                // Build failure reason for the bead note
                if (report.conflicts.length > 0) {
                    const files = report.conflicts.flatMap((c) => c.conflictFiles).slice(0, 10);
                    mergeFailureReason = `Merge conflict detected in branch foreman/${currentEntry.seed_id}.\nConflicting files:\n${files.map((f) => `  - ${f}`).join("\n") || "  (no file details available)"}`;
                }
                else if (report.prsCreated.length > 0) {
                    const pr = report.prsCreated[0];
                    mergeFailureReason = `Merge conflict: a PR was created for manual review.\nPR URL: ${pr.prUrl}\nBranch: ${pr.branchName}`;
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
                // Send merge-conflict mail for PRs created on conflict
                for (const pr of report.prsCreated) {
                    sendMail(store, currentEntry.run_id, "merge-conflict", {
                        seedId: pr.seedId,
                        branchName: pr.branchName,
                        prUrl: pr.prUrl,
                        prCreated: true,
                    });
                }
            }
            else if (report.testFailures.length > 0) {
                mq.updateStatus(currentEntry.id, "failed", { error: "Test failures" });
                failedCount += report.testFailures.length;
                // Check if this seed has exceeded the post-merge test retry limit.
                //
                // refinery.mergeCompleted() already called resetSeedToOpen() which returns
                // the bead to "open" status so the dispatcher re-dispatches it. If the seed
                // has failed post-merge tests too many times (typically due to pre-existing
                // failures on the dev branch that are unrelated to the feature branch), we
                // override that "open" reset with a permanent failure to break the cycle.
                //
                // The current failure was already recorded by refinery (run status = "test-failed")
                // so the count includes it.
                const testFailedRunsForSeed = store.getRunsByStatuses(["test-failed"], project.id)
                    .filter((r) => r.seed_id === currentEntry.seed_id);
                const totalTestFailCount = testFailedRunsForSeed.length;
                if (totalTestFailCount >= RETRY_CONFIG.maxRetries) {
                    // Retry limit exhausted — permanently mark the bead as failed to prevent
                    // infinite re-dispatch. The operator must manually re-open if appropriate.
                    enqueueMarkBeadFailed(store, currentEntry.seed_id, "auto-merge");
                    mergeFailureReason = [
                        `Post-merge tests failed ${totalTestFailCount} time(s) — retry limit (${RETRY_CONFIG.maxRetries}) exhausted.`,
                        `Pre-existing failures on the dev branch may be causing false positives.`,
                        `Manual investigation required. Use 'foreman retry ${currentEntry.seed_id}' after fixing dev-branch failures.`,
                    ].join(" ");
                    console.error(`[auto-merge] Seed ${currentEntry.seed_id} permanently failed after ${totalTestFailCount}` +
                        ` test-failed attempts (limit: ${RETRY_CONFIG.maxRetries}). Preventing infinite re-dispatch.`);
                }
                else {
                    // Still within retry limit — build a note explaining the transient failure.
                    const firstFailure = report.testFailures[0];
                    const errorSummary = firstFailure.error?.slice(0, 800) ?? "no details";
                    mergeFailureReason = [
                        `Post-merge tests failed (attempt ${totalTestFailCount}/${RETRY_CONFIG.maxRetries}).`,
                        `Will retry after the developer addresses the failures.`,
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
            }
            else {
                mq.updateStatus(currentEntry.id, "failed", { error: "No completed run found" });
                failedCount++;
                mergeFailureReason = `Merge failed: no completed run found for seed ${currentEntry.seed_id}. The run may have been deleted or not yet finalized.`;
                // Send merge-failed mail when no completed run was found in the queue
                sendMail(store, currentEntry.run_id, "merge-failed", {
                    seedId: currentEntry.seed_id,
                    reason: "no-completed-run",
                });
            }
        }
        catch (err) {
            const message = err instanceof Error ? err.message : String(err);
            mq.updateStatus(currentEntry.id, "failed", { error: message });
            failedCount++;
            // Capture the failure reason so the finally block can add it as a bead note
            mergeFailureReason = `Unexpected error during merge: ${message.slice(0, 800)}`;
            // Send merge-failed mail when an unexpected error occurs in the merge pipeline
            sendMail(store, currentEntry.run_id, "merge-failed", {
                seedId: currentEntry.seed_id,
                reason: "unexpected-error",
                error: message.slice(0, 400),
            });
        }
        finally {
            // Sync bead status after every merge outcome (success or failure).
            // Pass mergeFailureReason so the bead gets a note explaining the failure.
            // Always runs — ensures br reflects the latest run status immediately.
            await syncBeadStatusAfterMerge(store, taskClient, currentEntry.run_id, currentEntry.seed_id, projectPath, mergeFailureReason);
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
//# sourceMappingURL=auto-merge.js.map