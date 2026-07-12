/**
 * Finalize helper for agent-worker.
 *
 * Extracted as a separate module so it can be unit-tested independently
 * of the agent-worker process lifecycle (which calls main() on import).
 *
 * Responsibilities:
 *  1. Type-check the worktree (tsc --noEmit, non-fatal)
 *  2. Commit all changes with the task title/ID as the commit message
 *  3. Push the branch to origin
 *  4. Enqueue branch for merge (task will be closed by refinery after merge)
 *
 * Returns a FinalizeResult: { success, retryable }.
 */

import { writeFileSync, renameSync, existsSync } from "node:fs";
import { appendFile } from "node:fs/promises";
import { join, dirname } from "node:path";
import { execFileSync } from "node:child_process";
import { ForemanStore } from "../lib/store.js";
import { PIPELINE_TIMEOUTS } from "../lib/config.js";
import { enqueueToMergeQueue } from "./agent-worker-enqueue.js";
import { enqueueSetTaskStatus } from "./task-backend-ops.js";
import type { VcsBackend } from "../lib/vcs/index.js";
import { inferProjectPathFromWorkspacePath } from "../lib/workspace-paths.js";
import { resolveArtifactPath } from "../lib/report-paths.js";

// ── Types ─────────────────────────────────────────────────────────────────────

export interface FinalizeConfig {
  /** External/daemon project id when merge queue writes should go to Postgres. */
  projectId?: string;
  /** Run ID (used when enqueuing to the merge queue). */
  runId: string;
  /** Task identifier, e.g. "bd-ytzv". */
  taskId: string;
  /** Human-readable task title — used as the git commit message. */
  taskTitle: string;
  /** Absolute path to the git worktree directory. */
  worktreePath: string;
  /**
   * Absolute path to the project root (contains .tasks/).
   * Used as cwd for native task store commands. When omitted, Foreman infers the project root
   * from the workspace path so both legacy nested and external workspace roots work.
   */
  projectPath?: string;
}

/**
 * Result returned by finalize().
 *
 * - `success`: true when the git push succeeded (task was closed / enqueued).
 * - `retryable`: when success=false, indicates whether the caller should reset
 *   the task to "open" for re-dispatch.  Set to false for deterministic failures
 *   (e.g. diverged history that could not be rebased) to prevent an infinite
 *   re-dispatch loop (see bd-zwtr).
 */
export interface FinalizeResult {
  success: boolean;
  retryable: boolean;
  recommendedRecovery?: "clean-replay-from-main";
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/**
 * Rotate an existing report file so previous reports are preserved for
 * debugging.  Non-fatal — any rename error is silently swallowed.
 */
export function rotateReport(worktreePath: string, filename: string): void {
  const p = resolveArtifactPath(worktreePath, filename);
  if (!existsSync(p)) return;
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const ext = filename.endsWith(".md") ? ".md" : "";
  const base = ext ? filename.slice(0, -3) : filename;
  const rotated = join(dirname(p), `${base}.${stamp}${ext}`);
  try {
    renameSync(p, rotated);
  } catch {
    // Non-fatal — report will just be overwritten
  }
}

function log(msg: string): void {
  const ts = new Date().toISOString().slice(11, 23);
  console.error(`[foreman-worker ${ts}] ${msg}`);
}

// ── finalize ──────────────────────────────────────────────────────────────────

/**
 * Run VCS finalization: stage, commit, push, and enqueue for merge.
 *
 * Uses VcsBackend for all VCS operations — no direct execFileSync git calls.
 *
 * @returns `{ success: true, retryable: true }` when the push succeeded;
 *          `{ success: false, retryable: true }` for transient push failures;
 *          `{ success: false, retryable: false }` for deterministic failures
 *          (e.g. diverged history that could not be rebased via pull --rebase).
 */
export async function finalize(config: FinalizeConfig, logFile: string, vcs: VcsBackend): Promise<FinalizeResult> {
  const { taskId, taskTitle, worktreePath } = config;
  // `storeProjectPath` is used only to open the Postgres store for the merge
  // queue — it must never be undefined, so we infer it from the workspace path
  // when the caller didn't pass projectPath explicitly.
  const storeProjectPath = config.projectPath ?? inferProjectPathFromWorkspacePath(worktreePath);
  const buildOpts = { cwd: worktreePath, stdio: "pipe" as const, timeout: 60_000 };

  const report: string[] = [
    `# Finalize Report: ${taskTitle}`,
    "",
    `## Task: ${taskId}`,
    `## Timestamp: ${new Date().toISOString()}`,
    "",
  ];

  // Bug scan (pre-commit type check) — 60 s timeout to handle TypeScript cold-start
  try {
    execFileSync("npx", ["tsc", "--noEmit"], buildOpts);
    log(`[FINALIZE] Type check passed`);
    report.push(`## Build / Type Check`, `- Status: SUCCESS`, "");
  } catch (err: unknown) {
    const rawMsg = err instanceof Error ? err.message : String(err);
    // execFileSync throws with stderr in the message when stdio:"pipe"
    const stderr =
      err instanceof Error && "stderr" in err
        ? String((err as NodeJS.ErrnoException & { stderr?: Buffer }).stderr ?? "")
        : "";
    const detail = (stderr || rawMsg).slice(0, 500);
    log(`[FINALIZE] Type check failed: ${detail.slice(0, 200)}`);
    await appendFile(logFile, `[FINALIZE] Type check error:\n${detail}\n`);
    report.push(`## Build / Type Check`, `- Status: FAILED`, `- Errors:`, "```", detail, "```", "");
  }

  // Commit — use VcsBackend.stageAll() + VcsBackend.commit() + VcsBackend.getHeadId()
  let commitHash = "(none)";
  try {
    await vcs.stageAll(worktreePath);
    await vcs.commit(worktreePath, `${taskTitle} (${taskId})`);
    commitHash = await vcs.getHeadId(worktreePath);
    log(`[FINALIZE] Committed ${commitHash}`);
    report.push(`## Commit`, `- Status: SUCCESS`, `- Hash: ${commitHash}`, "");
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    if (msg.includes("nothing to commit")) {
      log(`[FINALIZE] Nothing to commit`);
      report.push(`## Commit`, `- Status: SKIPPED (nothing to commit)`, "");
    } else {
      log(`[FINALIZE] Commit failed: ${msg.slice(0, 200)}`);
      await appendFile(logFile, `[FINALIZE] Commit error: ${msg}\n`);
      report.push(`## Commit`, `- Status: FAILED`, `- Error: ${msg.slice(0, 300)}`, "");
    }
  }

  // Branch Verification — ensure we're on the correct branch before pushing.
  // Worktrees can end up in detached HEAD or on a wrong branch (e.g. after a
  // failed rebase or manual intervention), causing push to fail with
  // "src refspec does not match any".
  //
  // IMPORTANT: We do NOT auto-recover by checking out the expected branch.
  // Auto-recovery masks "branch drift" where workers switch to an ad-hoc branch
  // (e.g. `git checkout -b fix/foo`), commit real work there, then finalize
  // checks out the canonical branch and pushes from the wrong branch.
  // Fail-fast ensures the task fails visibly rather than silently losing work.
  const expectedBranch = `foreman/${taskId}`;
  let branchVerified = false;
  try {
    const currentBranch = await vcs.getCurrentBranch(worktreePath);
    if (currentBranch !== expectedBranch) {
      const msg = `[FINALIZE] BRANCH DRIFT: expected '${expectedBranch}', found '${currentBranch}' in '${worktreePath}'. Worktree must be on the canonical foreman/${taskId} branch. Will NOT auto-checkout — failing fast to preserve work.`;
      log(msg);
      await appendFile(logFile, `${msg}\n`);
      report.push(
        `## Branch Verification`,
        `- Expected: ${expectedBranch}`,
        `- Actual: ${currentBranch}`,
        `- Worktree: ${worktreePath}`,
        `- Status: FAILED (branch drift detected)`,
        `- Action: FAIL-FAST (no auto-checkout to preserve work on drifted branch)`,
        "",
      );
      branchVerified = false;
    } else {
      log(`[FINALIZE] Branch verified: ${currentBranch}`);
      report.push(
        `## Branch Verification`,
        `- Current: ${currentBranch}`,
        `- Status: OK`,
        "",
      );
      branchVerified = true;
    }
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    log(`[FINALIZE] Branch verification failed: ${msg.slice(0, 200)}`);
    await appendFile(logFile, `[FINALIZE] Branch verification error: ${msg}\n`);
    report.push(
      `## Branch Verification`,
      `- Expected: ${expectedBranch}`,
      `- Status: FAILED`,
      `- Error: ${msg.slice(0, 300)}`,
      "",
    );
  }

  // Enqueue to merge queue BEFORE push — source-of-truth write.
  //
  // Writing the queue entry BEFORE push eliminates the crash window where
  // the push succeeded but the agent died before enqueue() ran. With this order:
  //   - If the agent crashes after enqueue but before push: entry exists in
  //     'pending' state; on re-dispatch the agent will push the branch and
  //     refinery processes the pre-existing entry (enqueue is idempotent).
  //   - If the agent crashes after push: entry already exists; no duplicate push
  //     needed — refinery picks up the 'pending' entry and merges as normal.
  //   - If push ultimately fails: entry exists in 'pending' state; refinery will
  //     attempt the merge and fail gracefully, leaving the task for re-dispatch.
  //
  // Fire-and-forget semantics are preserved: an enqueue failure is non-fatal.
  if (branchVerified) {
    // Pre-compute modified files using VcsBackend.diff() (async) so we can pass
    // a synchronous closure to enqueueToMergeQueue.
    let modifiedFiles: string[] = [];
    try {
      // Get list of files changed between main and HEAD via unified diff,
      // then parse out just the filenames from "diff --git a/... b/..." headers.
      const diffOutput = await vcs.diff(worktreePath, "main", "HEAD");
      modifiedFiles = diffOutput
        .split("\n")
        .filter(l => l.startsWith("diff --git "))
        .map(l => {
          const match = /^diff --git a\/(.+) b\//.exec(l);
          return match ? match[1] : "";
        })
        .filter(Boolean);
    } catch {
      // Non-fatal — proceed with empty list
    }

    try {
      const enqueueStore = config.projectId ? undefined : ForemanStore.forProject(storeProjectPath);
      const enqueueResult = await enqueueToMergeQueue({
        ...(enqueueStore ? { db: enqueueStore.getDb() } : {}),
        projectId: config.projectId,
        taskId,
        runId: config.runId,
        worktreePath,
        getFilesModified: () => modifiedFiles,
      });
      enqueueStore?.close();

      if (enqueueResult.success) {
        log(`[FINALIZE] Enqueued to merge queue (pre-push)`);
        report.push(`## Merge Queue`, `- Status: ENQUEUED`, "");
      } else {
        log(`[FINALIZE] Merge queue enqueue failed (non-fatal): ${enqueueResult.error}`);
        report.push(`## Merge Queue`, `- Status: FAILED (non-fatal)`, `- Error: ${enqueueResult.error?.slice(0, 300)}`, "");
      }
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      log(`[FINALIZE] Merge queue enqueue failed (non-fatal): ${msg}`);
      report.push(`## Merge Queue`, `- Status: FAILED (non-fatal)`, `- Error: ${msg.slice(0, 300)}`, "");
    }
  }

  // Push — with automatic rebase recovery on non-fast-forward rejections.
  //
  // Non-fast-forward errors are deterministic (diverged history) and will
  // always fail on retry unless the local branch is rebased onto the remote.
  // Attempting fetch + rebase here resolves the common case where origin
  // received a commit (e.g. from a previous partial run) while the worktree
  // continued on a different history.  If the rebase itself fails (real
  // conflicts), we return retryable=false so the caller does NOT reset the
  // task to open — preventing the infinite re-dispatch loop described in bd-zwtr.
  let pushSucceeded = false;
  let pushRetryable = true; // default: transient failures may be retried
  let recommendedRecovery: FinalizeResult["recommendedRecovery"];
  if (!branchVerified) {
    log(`[FINALIZE] Skipping push (branch verification failed)`);
    report.push(`## Push`, `- Status: SKIPPED (branch verification failed)`, "");
  } else {
    try {
      await vcs.push(worktreePath, expectedBranch);
      log(`[FINALIZE] Pushed to origin`);
      report.push(`## Push`, `- Status: SUCCESS`, `- Branch: ${expectedBranch}`, "");
      pushSucceeded = true;
    } catch (pushErr: unknown) {
      const pushMsg = pushErr instanceof Error ? pushErr.message : String(pushErr);
      // "non-fast-forward" covers the standard rejection message.
      // "fetch first" covers the case where git phrases it differently (e.g. older git versions).
      // We do NOT trigger rebase for other rejection types (permission errors, missing refs, etc.).
      const isNonFastForward =
        pushMsg.includes("non-fast-forward") ||
        pushMsg.includes("fetch first");

      if (isNonFastForward) {
        log(`[FINALIZE] Push rejected (non-fast-forward) — attempting fetch + rebase`);
        await appendFile(logFile, `[FINALIZE] Push rejected (non-fast-forward): ${pushMsg}\n`);
        report.push(`## Push`, `- Status: REJECTED (non-fast-forward) — attempting rebase`, "");

        // Attempt fetch + rebase. A failed rebase is deterministic — do NOT reset task to open.
        let rebaseSucceeded = false;
        try {
          await vcs.fetch(worktreePath);
          const rebaseResult = await vcs.rebase(worktreePath, `origin/${expectedBranch}`);
          if (rebaseResult.success) {
            log(`[FINALIZE] Rebase succeeded — retrying push`);
            report.push(`## Rebase`, `- Status: SUCCESS`, "");
            rebaseSucceeded = true;
          } else {
            const conflictList = rebaseResult.conflictingFiles?.join(", ") ?? "";
            const detail = conflictList ? `conflicts in: ${conflictList}` : "rebase conflict";
            log(`[FINALIZE] Rebase failed: ${detail}`);
            await appendFile(logFile, `[FINALIZE] Rebase conflict: ${detail}\n`);
            report.push(`## Rebase`, `- Status: FAILED`, `- Error: ${detail.slice(0, 300)}`, `- Recommended recovery: clean replay from current main`, "");
            report.push(`## Push`, `- Status: FAILED (rebase could not resolve diverged history)`, "");
            // Abort any partial rebase to leave the worktree clean
            try { await vcs.abortRebase(worktreePath); } catch { /* already clean */ }
            // Deterministic failure — do NOT reset task to open (prevents infinite loop)
            pushRetryable = false;
            recommendedRecovery = "clean-replay-from-main";
          }
        } catch (rebaseErr: unknown) {
          const rebaseMsg = rebaseErr instanceof Error ? rebaseErr.message : String(rebaseErr);
          log(`[FINALIZE] Rebase failed: ${rebaseMsg.slice(0, 200)}`);
          await appendFile(logFile, `[FINALIZE] Rebase error: ${rebaseMsg}\n`);
          report.push(`## Rebase`, `- Status: FAILED`, `- Error: ${rebaseMsg.slice(0, 300)}`, `- Recommended recovery: clean replay from current main`, "");
          report.push(`## Push`, `- Status: FAILED (rebase could not resolve diverged history)`, "");
          // Abort any partial rebase to leave the worktree clean
          try { await vcs.abortRebase(worktreePath); } catch { /* already clean */ }
          // Deterministic failure — do NOT reset task to open (prevents infinite loop)
          pushRetryable = false;
          recommendedRecovery = "clean-replay-from-main";
        }

        // Retry push only if rebase succeeded. A post-rebase push failure is treated
        // as transient (retryable=true) — it is distinct from a rebase conflict.
        if (rebaseSucceeded) {
          try {
            await vcs.push(worktreePath, expectedBranch);
            log(`[FINALIZE] Pushed to origin (after rebase)`);
            report.push(`## Push`, `- Status: SUCCESS (after rebase)`, `- Branch: ${expectedBranch}`, "");
            pushSucceeded = true;
          } catch (retryPushErr: unknown) {
            const retryMsg = retryPushErr instanceof Error ? retryPushErr.message : String(retryPushErr);
            log(`[FINALIZE] Push failed after rebase: ${retryMsg.slice(0, 200)}`);
            await appendFile(logFile, `[FINALIZE] Post-rebase push error: ${retryMsg}\n`);
            report.push(`## Push`, `- Status: FAILED (after rebase)`, `- Error: ${retryMsg.slice(0, 300)}`, "");
            // Transient failure — allow retry
            pushRetryable = true;
          }
        }
      } else {
        log(`[FINALIZE] Push failed: ${pushMsg.slice(0, 200)}`);
        await appendFile(logFile, `[FINALIZE] Push error: ${pushMsg}\n`);
        report.push(`## Push`, `- Status: FAILED`, `- Error: ${pushMsg.slice(0, 300)}`, "");
        // Non-classification failures (network, permissions, etc.) may be transient
        pushRetryable = true;
      }
    }
  }

  // Note: merge queue enqueue already happened before push (pre-push enqueue above).
  // No second enqueue needed here — the pre-push entry covers the successful-push case too.

  // Task lifecycle: set task to 'review' after a successful push.
  // This signals "pipeline done, branch pushed, awaiting foreman merge".
  // Closing happens only after the branch successfully merges (via refinery.ts).
  // On push failure the task stays in_progress (caller resets to open via resetTaskToOpen).
  if (pushSucceeded) {
    // Queue the status update instead of calling native task store directly — prevents
    // Postgres contention with concurrent agent-workers (all native task store writes go
    // through the dispatcher's sequential drain).
    try {
      const statusStore = ForemanStore.forProject(storeProjectPath);
      enqueueSetTaskStatus(statusStore, taskId, "review", "agent-worker-finalize");
      statusStore.close();
      log(`[FINALIZE] Enqueued task ${taskId} → review — task will be closed by refinery after merge`);
      report.push(`## Task Status`, `- Status: AWAITING_MERGE (review)`, `- Note: task closed by refinery after successful merge`, "");
    } catch (brErr: unknown) {
      const brMsg = brErr instanceof Error ? brErr.message : String(brErr);
      log(`[FINALIZE] Warning: enqueue set-status review failed for ${taskId}: ${brMsg.slice(0, 200)}`);
      report.push(`## Task Status`, `- Status: AWAITING_MERGE`, `- Note: task status update to review failed (non-fatal)`, "");
    }
  } else {
    log(`[FINALIZE] Push failed for ${taskId} — merge queue entry written pre-push; refinery will handle gracefully on re-dispatch`);
    report.push(`## Task Status`, `- Status: PUSH_FAILED`, `- Note: merge queue entry written before push attempt`, "");
  }

  // Write finalize report
  try {
    rotateReport(worktreePath, "FINALIZE_REPORT.md");
    writeFileSync(join(worktreePath, "FINALIZE_REPORT.md"), report.join("\n"));
  } catch {
    // Non-fatal — finalize report is for debugging
  }

  return { success: pushSucceeded, retryable: pushRetryable, recommendedRecovery };
}
