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
 *  4. Enqueue the branch to the merge queue (only if push succeeded)
 *  5. Close the seed in the br backend (ONLY if push succeeded)
 *
 * Returns `true` when push succeeded (seed was closed); `false` otherwise.
 */

import { writeFileSync, renameSync, existsSync } from "node:fs";
import { appendFile } from "node:fs/promises";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { ForemanStore } from "../lib/store.js";
import { PIPELINE_TIMEOUTS } from "../lib/config.js";
import { enqueueToMergeQueue } from "./agent-worker-enqueue.js";
import { closeSeed } from "./task-backend-ops.js";

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
 * Run git finalization: add, commit, push, and close the seed.
 *
 * Uses execFileSync for safety — no shell interpolation.
 *
 * @returns `true` when the git push succeeded (seed is closed);
 *          `false` when the push failed (seed is left open for retry).
 */
export async function finalize(config: FinalizeConfig, logFile: string): Promise<boolean> {
  const { seedId, seedTitle, worktreePath } = config;
  // `storeProjectPath` is used only to open the SQLite store for the merge
  // queue — it must never be undefined, so we fall back to worktreePath/../..
  // (the conventional repo root for a worktree at <root>/.foreman-worktrees/<id>).
  // `closeSeed()` further below receives `config.projectPath` directly (which
  // may be undefined) because that function handles the undefined case
  // internally and resolves the path itself.
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

  // Push
  let pushSucceeded = false;
  if (!branchVerified) {
    log(`[FINALIZE] Skipping push (branch verification failed)`);
    report.push(`## Push`, `- Status: SKIPPED (branch verification failed)`, "");
  } else {
    try {
      execFileSync("git", ["push", "-u", "origin", expectedBranch], opts);
      log(`[FINALIZE] Pushed to origin`);
      report.push(`## Push`, `- Status: SUCCESS`, `- Branch: ${expectedBranch}`, "");
      pushSucceeded = true;
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      log(`[FINALIZE] Push failed: ${msg.slice(0, 200)}`);
      await appendFile(logFile, `[FINALIZE] Push error: ${msg}\n`);
      report.push(`## Push`, `- Status: FAILED`, `- Error: ${msg.slice(0, 300)}`, "");
    }
  }

  // Enqueue to merge queue (fire-and-forget — must not block finalization)
  if (pushSucceeded) {
    try {
      const enqueueStore = ForemanStore.forProject(storeProjectPath);
      const enqueueResult = enqueueToMergeQueue({
        db: enqueueStore.getDb(),
        seedId,
        runId: config.runId,
        worktreePath,
        getFilesModified: () => {
          const output = execFileSync("git", ["diff", "--name-only", "main...HEAD"], opts).toString().trim();
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

  // Close bead (br backend) — ONLY if push succeeded.
  // If push failed the seed must stay open so it can be retried manually.
  // Pass projectPath (repo root) so br finds .beads/ — the worktree dir has none.
  if (pushSucceeded) {
    await closeSeed(seedId, config.projectPath);
    log(`[FINALIZE] Closed seed ${seedId}`);
    report.push(`## Seed Close`, `- Status: SUCCESS`, "");
  } else {
    log(`[FINALIZE] Skipped seed close (push failed) for ${seedId}`);
    report.push(`## Seed Close`, `- Status: SKIPPED (push failed)`, "");
  }

  // Write finalize report
  try {
    rotateReport(worktreePath, "FINALIZE_REPORT.md");
    writeFileSync(join(worktreePath, "FINALIZE_REPORT.md"), report.join("\n"));
  } catch {
    // Non-fatal — finalize report is for debugging
  }

  return pushSucceeded;
}
