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

import { loadProjectConfig, resolveVcsConfig } from "../lib/project-config.js";
import type { ForemanStore, Run } from "../lib/store.js";
import type { ITaskClient } from "../lib/task-client.js";
import { VcsBackendFactory } from "../lib/vcs/index.js";
import type { VcsBackend } from "../lib/vcs/interface.js";
import { MergeQueue, RETRY_CONFIG } from "./merge-queue.js";
import { ElixirMergeQueue } from "./elixir-merge-queue.js";
import { Refinery } from "./refinery.js";
import { mapRunStatusToNativeTaskStatus } from "../lib/run-status.js";
import { enqueueMarkTaskFailed, enqueueAddNotesToTask } from "./task-backend-ops.js";

type Awaitable<T> = T | Promise<T>;

export interface AutoMergeReadLookup {
  getRun(id: string): Awaitable<Run | null>;
  getRunsByStatus(status: Run["status"], projectId?: string): Awaitable<Run[]>;
  getRunsByStatuses(statuses: Run["status"][], projectId?: string): Awaitable<Run[]>;
  getRunsByBaseBranch(baseBranch: string, projectId?: string): Awaitable<Run[]>;
}

async function createAutoMergeVcsBackend(projectPath: string): Promise<VcsBackend> {
  const projectCfg = loadProjectConfig(projectPath);
  const vcsConfig = resolveVcsConfig(undefined, projectCfg?.vcs);
  return VcsBackendFactory.create(vcsConfig, projectPath);
}

// ── Helpers ──────────────────────────────────────────────────────────────────

/**
 * Fire-and-forget helper to send a mail message via the store.
 * Uses store.sendMessage() directly — same pattern as Refinery.sendMail().
 * Never throws — failures are silently ignored (mail is optional infrastructure).
 */
function sendMail(
  store: Pick<ForemanStore, "sendMessage">,
  runId: string,
  subject: string,
  body: Record<string, unknown>,
): void {
  void Promise.resolve().then(() => store.sendMessage(runId, "auto-merge", "foreman", subject, JSON.stringify({
      ...body,
      timestamp: new Date().toISOString(),
    }))).catch(() => {
    // Non-fatal — mail is optional infrastructure
  });
}

/**
 * Immediately sync a task's status in the native task store after a merge outcome.
 *
 * Fetches the latest run status from Postgres, maps it to the expected task
 * status via mapRunStatusToNativeTaskStatus(), and updates the native task store.
 *
 * When `failureReason` is provided (non-empty), logs it (native task store
 * does not have a notes field for failure context).
 *
 * Non-fatal — logs a warning on failure and lets the caller continue.
 */
export async function syncTaskStatusAfterMerge(
  store: ForemanStore,
  taskClient: ITaskClient,
  runId: string,
  taskId: string,
  projectPath: string,
  failureReason?: string,
  readLookup: Pick<AutoMergeReadLookup, "getRun"> = store,
): Promise<void> {
  const run = await Promise.resolve(readLookup.getRun(runId));
  if (!run) return;

  const expectedStatus = mapRunStatusToNativeTaskStatus(run.status);
  const existingTask = await Promise.resolve(store.getTaskById?.(taskId));
  if (expectedStatus === "review" && (existingTask?.status === "closed" || existingTask?.status === "merged")) {
    return;
  }

  // Update the task status directly in the native task store.
  // Multiple agent workers can trigger autoMerge concurrently — the native
  // task store uses Postgres MVCC for safe concurrent writes.
  await Promise.resolve(store.updateTaskStatus(taskId, expectedStatus));

  if (failureReason) {
    enqueueAddNotesToTask(store, taskId, failureReason, "auto-merge");
  }
}

// ── Auto-Merge ───────────────────────────────────────────────────────────────

/** Options for the autoMerge function. */
export interface AutoMergeOpts {
  store: ForemanStore;
  taskClient: ITaskClient;
  projectPath: string;
  registeredProjectId?: string;
  readLookup?: AutoMergeReadLookup;
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
  overrideRun?: Run;
}

/** Result summary returned by autoMerge(). */
export interface AutoMergeScopedResult {
  runId: string;
  merged: number;
  conflicts: number;
  failed: number;
}

export interface AutoMergeResult {
  merged: number;
  conflicts: number;
  failed: number;
  /** Outcome for opts.runId only. Present only when opts.runId was provided. */
  target?: AutoMergeScopedResult;
}

interface MergeQueueLike {
  reconcile(repoPath: string): Promise<{ enqueued: number; skipped: number; invalidBranch: number; failedToEnqueue: Array<{ run_id: string; task_id: string; reason: string }> }>;
  dequeue(): Promise<{
    id: number;
    branch_name: string;
    task_id: string;
    run_id: string;
    operation?: "auto_merge" | "create_pr";
  } | null>;
  updateStatus(id: number, status: "pending" | "merging" | "merged" | "conflict" | "failed", extra?: { resolvedTier?: number; error?: string; completedAt?: string; lastAttemptedAt?: string; retryCount?: number }): Promise<void>;
  getRetryableEntries(): Promise<Array<{ id: number; task_id: string; retry_count: number }>>;
  reEnqueue(id: number): Promise<boolean>;
}

function wrapLocalMergeQueue(queue: MergeQueue, store: ForemanStore, projectPath: string): MergeQueueLike {
  return {
    reconcile: async () => queue.reconcile(store.getDb(), projectPath),
    dequeue: async () => queue.dequeue(),
    updateStatus: async (id, status, extra) => queue.updateStatus(id, status, extra),
    getRetryableEntries: async () => queue.getRetryableEntries(),
    reEnqueue: async (id) => queue.reEnqueue(id),
  };
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
 *   - merge-complete  — branch merged successfully, task closed
 *   - merge-conflict  — conflict detected, PR created or manual intervention needed
 *   - merge-failed    — merge failed (test failures, no completed run, or unexpected error)
 *   - task-closed     — task status synced in native task store after merge outcome
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
  const {
    store,
    taskClient,
    projectPath,
    registeredProjectId,
    readLookup = store,
    overrideRun,
    runId: optsRunId,
  } = opts;
  const vcs = await createAutoMergeVcsBackend(projectPath);
  const targetBranch = opts.targetBranch ?? await vcs.detectDefaultBranch(projectPath);

  let projectId = registeredProjectId;
  if (!projectId) {
    const project = store.getProjectByPath(projectPath);
    if (!project) {
      // No project registered — skip silently (init not run yet)
      return { merged: 0, conflicts: 0, failed: 0 };
    }
    projectId = project.id;
  }

  const mq: MergeQueueLike = registeredProjectId
    ? new ElixirMergeQueue(registeredProjectId, projectPath)
    : wrapLocalMergeQueue(new MergeQueue(store.getDb()), store, projectPath);
  const refinery = new Refinery(store, taskClient, projectPath, vcs, {
    runLookup: readLookup,
    ...(registeredProjectId ? { registeredProjectId } : {}),
  });

  // Reconcile completed runs into the queue
  await mq.reconcile(projectPath);

  let mergedCount = 0;
  let conflictCount = 0;
  let failedCount = 0;
  const target = optsRunId
    ? { runId: optsRunId, merged: 0, conflicts: 0, failed: 0 }
    : undefined;

  let entry = await mq.dequeue();
  while (entry) {
    const currentEntry = entry;
    // Track the failure reason to attach as a task note (if any failure occurs).
    // Declared outside try/catch so it's accessible in the finally block.
    let mergeFailureReason: string | undefined;
    // Track whether this queue entry resulted in a successful merge so that
    // task-closed mail is only sent on actual success (Fix 2).
    let mergeSucceeded = false;

    // Determine merge intent from the queue entry first, falling back to the
    // run's merge_strategy for legacy queue rows that predate operation.
    const run = overrideRun?.id === currentEntry.run_id
        ? overrideRun
        : await Promise.resolve(readLookup.getRun(currentEntry.run_id));
    const mergeStrategy: 'auto' | 'pr' | 'none' = (run?.merge_strategy as 'auto' | 'pr' | 'none') ?? 'auto';
    const mergeOperation = currentEntry.operation
      ?? (mergeStrategy === 'pr' ? 'create_pr' : 'auto_merge');

    if (!currentEntry.operation && mergeStrategy === 'none') {
      // Skip merge entirely — mark as completed
      await mq.updateStatus(currentEntry.id, 'merged', { completedAt: new Date().toISOString() });
      store.updateRun(currentEntry.run_id, { status: 'completed' });
      mergedCount += 1;
      if (target && currentEntry.run_id === target.runId) target.merged += 1;
      mergeSucceeded = true;
      entry = await mq.dequeue();
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
        await mq.updateStatus(currentEntry.id, 'merged', { completedAt: new Date().toISOString() });
        await syncTaskStatusAfterMerge(
          store,
          taskClient,
          currentEntry.run_id,
          currentEntry.task_id,
          projectPath,
          `PR created for manual review.\nPR URL: ${pr.prUrl}`,
          readLookup,
        );
        sendMail(store, currentEntry.run_id, "merge-conflict", {
          taskId: currentEntry.task_id,
          branchName: pr.branchName,
          prUrl: pr.prUrl,
          prCreated: true,
        });
        conflictCount += 1;
        if (target && currentEntry.run_id === target.runId) target.conflicts += 1;
        entry = await mq.dequeue();
        continue;
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        mergeFailureReason = `Failed to create PR: ${message}`;
        await mq.updateStatus(currentEntry.id, 'failed', { error: message });
        failedCount += 1;
        if (target && currentEntry.run_id === target.runId) target.failed += 1;
        entry = await mq.dequeue();
        continue;
      }
    }

    try {
      const injectedRunMatchesEntry = optsRunId === currentEntry.run_id || overrideRun?.id === currentEntry.run_id;
      const effectiveRunId = optsRunId === currentEntry.run_id
        ? optsRunId
        : overrideRun?.id === currentEntry.run_id
          ? overrideRun.id
          : currentEntry.run_id;
      const report = typeof (refinery as Refinery & { mergePullRequest?: typeof refinery.mergePullRequest }).mergePullRequest === "function"
        ? await refinery.mergePullRequest({
          targetBranch,
          runId: effectiveRunId,
        })
        : await refinery.mergeCompleted({
            targetBranch,
            runTests: false,
            projectId,
            taskId: currentEntry.task_id,
            runId: effectiveRunId,
            ...(injectedRunMatchesEntry && overrideRun?.id === currentEntry.run_id ? { overrideRun } : {}),
        });


      if (report.merged.length > 0) {
        await mq.updateStatus(currentEntry.id, "merged", { completedAt: new Date().toISOString() });
        mergedCount += report.merged.length;
        if (target && currentEntry.run_id === target.runId) target.merged += report.merged.length;
        mergeSucceeded = true;

        // Send merge-complete mail for each successfully merged run
        for (const mergedRun of report.merged) {
          sendMail(store, currentEntry.run_id, "merge-complete", {
            taskId: mergedRun.taskId,
            branchName: mergedRun.branchName,
            targetBranch,
          });
        }
      } else if (report.conflicts.length > 0 || report.prsCreated.length > 0) {
        await mq.updateStatus(currentEntry.id, "conflict", { error: "Code conflicts" });
        const conflictsForEntry = report.conflicts.length + report.prsCreated.length;
        conflictCount += conflictsForEntry;
        if (target && currentEntry.run_id === target.runId) target.conflicts += conflictsForEntry;

        // Build failure reason for the task note
        if (report.conflicts.length > 0) {
          const files = report.conflicts.flatMap((c) => c.conflictFiles).slice(0, 10);
          mergeFailureReason = `Merge conflict detected in branch foreman/${currentEntry.task_id}.\nConflicting files:\n${files.map((f) => `  - ${f}`).join("\n") || "  (no file details available)"}`;
        }
        // Send merge-conflict mail for each conflicted run
        for (const conflictRun of report.conflicts) {
          sendMail(store, currentEntry.run_id, "merge-conflict", {
            taskId: conflictRun.taskId,
            branchName: conflictRun.branchName,
            conflictFiles: conflictRun.conflictFiles,
            prCreated: false,
          });
        }
        for (const pr of report.prsCreated) {
          sendMail(store, currentEntry.run_id, "merge-conflict", {
            taskId: pr.taskId,
            branchName: pr.branchName,
            prUrl: pr.prUrl,
            prCreated: true,
          });
        }
      } else if (report.testFailures.length > 0) {
        await mq.updateStatus(currentEntry.id, "failed", { error: "Test failures" });
        failedCount += report.testFailures.length;
        if (target && currentEntry.run_id === target.runId) target.failed += report.testFailures.length;

        // Count repeated post-merge test failures for diagnostics. Retries are
        // now explicit/human-driven rather than automatic reopen-to-open.
        const testFailedRunsForTask = (await Promise.resolve(readLookup.getRunsByStatuses(["test-failed"], projectId)))
          .filter((r: { task_id: string }) => r.task_id === currentEntry.task_id);
        const totalTestFailCount = testFailedRunsForTask.length;

        if (totalTestFailCount >= RETRY_CONFIG.maxRetries) {
          // Retry limit exhausted — permanently mark the task as failed.
          enqueueMarkTaskFailed(store, currentEntry.task_id, "auto-merge");
          mergeFailureReason = [
            `Post-merge tests failed ${totalTestFailCount} time(s) — retry limit (${RETRY_CONFIG.maxRetries}) exhausted.`,
            `Pre-existing failures on the dev branch may be causing false positives.`,
            `Manual investigation required. Use 'foreman retry ${currentEntry.task_id}' after fixing dev-branch failures.`,
          ].join(" ");
          console.error(
            `[auto-merge] Task ${currentEntry.task_id} permanently failed after ${totalTestFailCount}` +
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
            taskId: failedRun.taskId,
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
        await mq.updateStatus(currentEntry.id, 'failed', { error: mergeFailureReason });
        failedCount += 1;
        if (target && currentEntry.run_id === target.runId) target.failed += 1;
      } else {
        await mq.updateStatus(currentEntry.id, "failed", { error: "No completed run found" });
        failedCount++;
        if (target && currentEntry.run_id === target.runId) target.failed += 1;
        mergeFailureReason = `Merge failed: no mergeable run found for task ${currentEntry.task_id}. The run may have been deleted or not yet finalized.`;

        // Send merge-failed mail when no completed run was found in the queue
        sendMail(store, currentEntry.run_id, "merge-failed", {
          taskId: currentEntry.task_id,
          reason: "no-completed-run",
        });
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      mergeFailureReason = `PR merge error: ${message.slice(0, 800)}`;
      await mq.updateStatus(currentEntry.id, 'failed', { error: mergeFailureReason });
      failedCount += 1;
      if (target && currentEntry.run_id === target.runId) target.failed += 1;

      sendMail(store, currentEntry.run_id, 'merge-failed', {
        taskId: currentEntry.task_id,
        reason: 'unexpected-error',
        error: message.slice(0, 400),
      });
    } finally {
      // Sync task status after every merge outcome (success or failure).
      // Pass mergeFailureReason so the task gets a note explaining the failure.
      // Always runs — ensures native task store reflects the latest run status immediately.
      await syncTaskStatusAfterMerge(
        store,
        taskClient,
        currentEntry.run_id,
        currentEntry.task_id,
        projectPath,
        mergeFailureReason,
        readLookup,
      );

      // Send task-closed mail only when the merge actually succeeded.
      // Sending it on failure paths creates a misleading inbox entry where the
      // task shows OPEN in native task store but "closed" in pipeline mail (Fix 2).
      if (mergeSucceeded) {
        sendMail(store, currentEntry.run_id, "task-closed", {
          taskId: currentEntry.task_id,
        });
      }
    }

    entry = await mq.dequeue();
  }

  return {
    merged: mergedCount,
    conflicts: conflictCount,
    failed: failedCount,
    ...(target ? { target } : {}),
  };
}
