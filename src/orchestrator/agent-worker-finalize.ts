/**
 * Finalize helper for agent-worker.
 *
 * Extracted as a separate module so it can be unit-tested independently
 * of the agent-worker process lifecycle (which calls main() on import).
 *
 * Responsibilities:
 *  1. Type-check the worktree (tsc --noEmit, non-fatal)
 *  2. Commit all changes with the seed title/ID as the commit message
 *  3. Push the branch to origin
 *  4. Enqueue branch for merge (seed will be closed by refinery after merge)
 *
 * Returns a FinalizeResult: { success, retryable }.
 */

import { writeFileSync, renameSync, existsSync } from "node:fs";
import { appendFile } from "node:fs/promises";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { homedir } from "node:os";
import { ForemanStore } from "../lib/store.js";
import { PIPELINE_TIMEOUTS } from "../lib/config.js";
import { enqueueToMergeQueue } from "./agent-worker-enqueue.js";
import { detectDefaultBranch } from "../lib/git.js";

// ── Types ─────────────────────────────────────────────────────────────────────

export interface FinalizeConfig {
  /** Run ID (used when enqueuing to the merge queue). */
  runId: string;
  /** Seed identifier, e.g. "bd-ytzv". */
  seedId: string;
  /** Human-readable seed title — used as the git commit message. */
  seedTitle: string;
  /** Absolute path to the git worktree directory. */
  worktreePath: string;
  /**
   * Absolute path to the project root (contains .beads/).
   * Used as cwd for br commands. Defaults to worktreePath/../..
   * when not provided.
   */
  projectPath?: string;
}

/**
 * Result returned by finalize().
 *
 * - `success`: true when the git push succeeded (seed was closed / enqueued).
 * - `retryable`: when success=false, indicates whether the caller should reset
 *   the seed to "open" for re-dispatch.  Set to false for deterministic failures
 *   (e.g. diverged history that could not be rebased) to prevent an infinite
 *   re-dispatch loop (see bd-zwtr).
 */
export interface FinalizeResult {
  success: boolean;
  retryable: boolean;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/**
 * Rotate an existing report file so previous reports are preserved for
 * debugging.  Non-fatal — any rename error is silently swallowed.
 */
export function rotateReport(worktreePath: string, filename: string): void {
  const p = join(worktreePath, filename);
  if (!existsSync(p)) return;
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const ext = filename.endsWith(".md") ? ".md" : "";
  const base = ext ? filename.slice(0, -3) : filename;
  const rotated = join(worktreePath, `${base}.${stamp}${ext}`);
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
 * Run git finalization: add, commit, push, and enqueue for merge.
 *
 * Uses execFileSync for safety — no shell interpolation.
 *
 * @returns `{ success: true, retryable: true }` when the git push succeeded;
 *          `{ success: false, retryable: true }` for transient push failures;
 *          `{ success: false, retryable: false }` for deterministic failures
 *          (e.g. diverged history that could not be rebased via pull --rebase).
 */
export async function finalize(config: FinalizeConfig, logFile: string): Promise<FinalizeResult> {
  const { seedId, seedTitle, worktreePath } = config;
  // `storeProjectPath` is used only to open the SQLite store for the merge
  // queue — it must never be undefined, so we fall back to worktreePath/../..
  // (the conventional repo root for a worktree at <root>/.foreman-worktrees/<id>).
  const storeProjectPath = config.projectPath ?? join(worktreePath, "..", "..");
  const opts = { cwd: worktreePath, stdio: "pipe" as const, timeout: PIPELINE_TIMEOUTS.gitOperationMs };

  const report: string[] = [
    `# Finalize Report: ${seedTitle}`,
    "",
    `## Seed: ${seedId}`,
    `## Timestamp: ${new Date().toISOString()}`,
    "",
  ];

  // Bug scan (pre-commit type check) — 60 s timeout to handle TypeScript cold-start
  const buildOpts = { ...opts, timeout: 60_000 };
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

  // Commit
  let commitHash = "(none)";
  try {
    execFileSync("git", ["add", "-A"], opts);
    execFileSync("git", ["commit", "-m", `${seedTitle} (${seedId})`], opts);
    commitHash = execFileSync("git", ["rev-parse", "--short", "HEAD"], opts).toString().trim();
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
  // failed rebase or manual intervention), causing `git push foreman/<seedId>`
  // to fail with "src refspec does not match any".
  const expectedBranch = `foreman/${seedId}`;
  let branchVerified = false;
  try {
    const currentBranch = execFileSync("git", ["rev-parse", "--abbrev-ref", "HEAD"], opts)
      .toString()
      .trim();
    if (currentBranch !== expectedBranch) {
      log(`[FINALIZE] Branch mismatch: on '${currentBranch}', expected '${expectedBranch}' — attempting checkout`);
      execFileSync("git", ["checkout", expectedBranch], opts);
      log(`[FINALIZE] Checked out ${expectedBranch}`);
      report.push(
        `## Branch Verification`,
        `- Was: ${currentBranch}`,
        `- Expected: ${expectedBranch}`,
        `- Status: RECOVERED (checkout succeeded)`,
        "",
      );
    } else {
      log(`[FINALIZE] Branch verified: ${currentBranch}`);
      report.push(
        `## Branch Verification`,
        `- Current: ${currentBranch}`,
        `- Status: OK`,
        "",
      );
    }
    branchVerified = true;
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

  // Push — with automatic rebase recovery on non-fast-forward rejections.
  //
  // Non-fast-forward errors are deterministic (diverged history) and will
  // always fail on retry unless the local branch is rebased onto the remote.
  // Attempting git pull --rebase here resolves the common case where origin
  // received a commit (e.g. from a previous partial run) while the worktree
  // continued on a different history.  If the rebase itself fails (real
  // conflicts), we return retryable=false so the caller does NOT reset the
  // seed to open — preventing the infinite re-dispatch loop described in bd-zwtr.
  let pushSucceeded = false;
  let pushRetryable = true; // default: transient failures may be retried
  if (!branchVerified) {
    log(`[FINALIZE] Skipping push (branch verification failed)`);
    report.push(`## Push`, `- Status: SKIPPED (branch verification failed)`, "");
  } else {
    try {
      execFileSync("git", ["push", "-u", "origin", expectedBranch], opts);
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
        log(`[FINALIZE] Push rejected (non-fast-forward) — attempting git pull --rebase`);
        await appendFile(logFile, `[FINALIZE] Push rejected (non-fast-forward): ${pushMsg}\n`);
        report.push(`## Push`, `- Status: REJECTED (non-fast-forward) — attempting rebase`, "");

        // Attempt rebase. A failed rebase is deterministic — do NOT reset seed to open.
        let rebaseSucceeded = false;
        try {
          execFileSync("git", ["pull", "--rebase", "origin", expectedBranch], opts);
          log(`[FINALIZE] Rebase succeeded — retrying push`);
          report.push(`## Rebase`, `- Status: SUCCESS`, "");
          rebaseSucceeded = true;
        } catch (rebaseErr: unknown) {
          const rebaseMsg = rebaseErr instanceof Error ? rebaseErr.message : String(rebaseErr);
          log(`[FINALIZE] Rebase failed: ${rebaseMsg.slice(0, 200)}`);
          await appendFile(logFile, `[FINALIZE] Rebase error: ${rebaseMsg}\n`);
          report.push(`## Rebase`, `- Status: FAILED`, `- Error: ${rebaseMsg.slice(0, 300)}`, "");
          report.push(`## Push`, `- Status: FAILED (rebase could not resolve diverged history)`, "");
          // Abort any partial rebase to leave the worktree clean
          try { execFileSync("git", ["rebase", "--abort"], opts); } catch { /* already clean */ }
          // Deterministic failure — do NOT reset seed to open (prevents infinite loop)
          pushRetryable = false;
        }

        // Retry push only if rebase succeeded. A post-rebase push failure is treated
        // as transient (retryable=true) — it is distinct from a rebase conflict.
        if (rebaseSucceeded) {
          try {
            execFileSync("git", ["push", "-u", "origin", expectedBranch], opts);
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

  // Enqueue to merge queue (fire-and-forget — must not block finalization)
  if (pushSucceeded) {
    const defaultBranch = await detectDefaultBranch(storeProjectPath).catch(() => "main");
    try {
      const enqueueStore = ForemanStore.forProject(storeProjectPath);
      const enqueueResult = enqueueToMergeQueue({
        db: enqueueStore.getDb(),
        seedId,
        runId: config.runId,
        worktreePath,
        getFilesModified: () => {
          const output = execFileSync("git", ["diff", "--name-only", `${defaultBranch}...HEAD`], opts).toString().trim();
          return output ? output.split("\n") : [];
        },
      });
      enqueueStore.close();

      if (enqueueResult.success) {
        log(`[FINALIZE] Enqueued to merge queue`);
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

  // Seed lifecycle: set bead to 'review' after a successful push.
  // This signals "pipeline done, branch pushed, awaiting foreman merge".
  // Closing happens only after the branch successfully merges (via refinery.ts).
  // On push failure the bead stays in_progress (caller resets to open via resetSeedToOpen).
  if (pushSucceeded) {
    const brBin = join(homedir(), ".local", "bin", "br");
    const brOpts = {
      stdio: "pipe" as const,
      timeout: PIPELINE_TIMEOUTS.beadClosureMs,
      ...(storeProjectPath ? { cwd: storeProjectPath } : {}),
    };
    try {
      execFileSync(brBin, ["update", seedId, "--status", "review"], brOpts);
      log(`[FINALIZE] Seed ${seedId} set to review — bead will be closed by refinery after merge`);
      report.push(`## Seed Status`, `- Status: AWAITING_MERGE (review)`, `- Note: bead closed by refinery after successful merge`, "");
    } catch (brErr: unknown) {
      const brMsg = brErr instanceof Error ? brErr.message : String(brErr);
      log(`[FINALIZE] Warning: br update --status review failed for ${seedId}: ${brMsg.slice(0, 200)}`);
      await appendFile(logFile, `[FINALIZE] br update review error: ${brMsg}\n`);
      report.push(`## Seed Status`, `- Status: AWAITING_MERGE`, `- Note: bead status update to review failed (non-fatal)`, "");
    }
  } else {
    log(`[FINALIZE] Skipped merge queue — push failed for ${seedId}`);
    report.push(`## Seed Status`, `- Status: SKIPPED (push failed)`, "");
  }

  // Write finalize report
  try {
    rotateReport(worktreePath, "FINALIZE_REPORT.md");
    writeFileSync(join(worktreePath, "FINALIZE_REPORT.md"), report.join("\n"));
  } catch {
    // Non-fatal — finalize report is for debugging
  }

  return { success: pushSucceeded, retryable: pushRetryable };
}
