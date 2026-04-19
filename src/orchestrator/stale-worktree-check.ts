/**
 * Stale worktree check — Pre-flight rebase detection and auto-rebase for dispatch.
 *
 * Before spawning an agent for an existing worktree, verifies the worktree
 * is rebased onto the latest target branch. If behind, optionally auto-rebases.
 *
 * Logs worktree-rebased / worktree-rebase-failed events to the store.
 *
 * @module src/orchestrator/stale-worktree-check
 */

import type { ForemanStore } from "../lib/store.js";
import type { VcsBackend } from "../lib/vcs/index.js";

// ── Types ─────────────────────────────────────────────────────────────────

/**
 * Result of a stale worktree check.
 */
export interface StaleWorktreeCheckResult {
  /** True if the worktree was already up-to-date. */
  rebased: boolean;
  /** True if an auto-rebase was performed. */
  autoRebasePerformed: boolean;
  /** Error message if rebase failed. */
  error?: string;
  /** Conflicting files if rebase failed. */
  conflictingFiles?: string[];
}

/**
 * Options for stale worktree checking.
 */
export interface StaleWorktreeCheckOptions {
  /** Whether to auto-rebase when stale. Default: true. */
  autoRebase?: boolean;
  /** Whether to fail when rebase has conflicts. Default: true. */
  failOnConflict?: boolean;
}

/**
 * Stale detection result including worktree state.
 */
export interface StaleDetectionResult {
  /** Whether the worktree is behind the target branch. */
  isStale: boolean;
  /** Current HEAD commit hash. */
  localHead: string;
  /** Target branch tip commit hash. */
  remoteHead: string;
  /** Branch name checked against. */
  targetBranch: string;
}

// ── Main function ─────────────────────────────────────────────────────────

/**
 * Check if a worktree is stale (behind its target branch) and optionally auto-rebase.
 *
 * Algorithm:
 * 1. Get local HEAD commit via `vcs.getHeadId()`
 * 2. Fetch origin via `vcs.fetch()`
 * 3. Resolve `origin/<targetBranch>` via `vcs.resolveRef()`
 * 4. If `localHead !== remoteHead`:
 *    - If `opts.autoRebase !== false`: attempt `vcs.rebase()`
 *    - On success: log `worktree-rebased` event, return `{ rebased: true, autoRebasePerformed: true }`
 *    - On failure: log `worktree-rebase-failed` event, return `{ rebased: false, ... }`
 *      (if `opts.failOnConflict !== false`, throw the error)
 * 5. If `localHead === remoteHead`: return `{ rebased: true, autoRebasePerformed: false }`
 *
 * Fresh worktree handling: If the branch doesn't exist yet (no prior commits),
 * skip the rebase check entirely — this is a new worktree, not a stale one.
 *
 * @param vcs - VCS backend instance
 * @param worktreePath - Absolute path to the worktree
 * @param targetBranch - Target branch name (e.g. "main", "dev")
 * @param store - ForemanStore for event logging
 * @param projectId - Foreman project ID
 * @param runId - Current run ID
 * @param seedId - Seed identifier
 * @param opts - Options: autoRebase (default: true), failOnConflict (default: true)
 * @returns StaleWorktreeCheckResult
 */
export async function checkAndRebaseStaleWorktree(
  vcs: VcsBackend,
  worktreePath: string,
  targetBranch: string,
  store: ForemanStore,
  projectId: string,
  runId: string,
  seedId: string,
  opts?: StaleWorktreeCheckOptions,
): Promise<StaleWorktreeCheckResult> {
  const autoRebase = opts?.autoRebase ?? true;
  const failOnConflict = opts?.failOnConflict ?? true;

  // ── Step 1: Get local HEAD ────────────────────────────────────────────
  let localHead: string;
  try {
    localHead = await vcs.getHeadId(worktreePath);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    // getHeadId can fail if the worktree has no commits (fresh worktree)
    // In that case, skip the stale check — it's not stale, it's new
    if (msg.includes("no commits") || msg.includes("empty repository") || msg.includes("does not have any commits")) {
      return { rebased: true, autoRebasePerformed: false };
    }
    throw err;
  }

  // ── Step 2: Fetch origin ───────────────────────────────────────────────
  try {
    await vcs.fetch(worktreePath);
  } catch (fetchErr) {
    // Fetch failures are non-fatal — we can still compare local HEAD with cached remote refs
    const fetchMsg = fetchErr instanceof Error ? fetchErr.message : String(fetchErr);
    console.warn(`[StaleWorktreeCheck] Fetch failed (non-fatal): ${fetchMsg}`);
  }

  // ── Step 3: Resolve remote HEAD ─────────────────────────────────────────
  let remoteHead: string;
  try {
    remoteHead = await vcs.resolveRef(worktreePath, `origin/${targetBranch}`);
  } catch (err) {
    // If origin/targetBranch doesn't exist, skip the stale check
    const msg = err instanceof Error ? err.message : String(err);
    if (msg.includes("unknown revision") || msg.includes("not found") || msg.includes("no such")) {
      return { rebased: true, autoRebasePerformed: false };
    }
    throw err;
  }

  // ── Step 4: Compare ─────────────────────────────────────────────────────
  if (localHead === remoteHead) {
    // Already up-to-date — no rebase needed
    return { rebased: true, autoRebasePerformed: false };
  }

  // Worktree is behind — check if auto-rebase is enabled
  if (!autoRebase) {
    console.warn(
      `[StaleWorktreeCheck] Worktree for ${seedId} is stale (behind origin/${targetBranch}) but auto-rebase is disabled`,
    );
    return {
      rebased: false,
      autoRebasePerformed: false,
      error: `Worktree is stale (local: ${localHead.slice(0, 8)}, origin/${targetBranch}: ${remoteHead.slice(0, 8)}). Run 'foreman reset' or rebase manually.`,
    };
  }

  // ── Step 5: Attempt rebase ────────────────────────────────────────────
  console.log(
    `[StaleWorktreeCheck] Worktree for ${seedId} is stale — auto-rebasing onto origin/${targetBranch}`,
  );

  try {
    const rebaseResult = await vcs.rebase(worktreePath, `origin/${targetBranch}`);

    if (rebaseResult.success) {
      // Rebase succeeded
      store.logEvent(projectId, "worktree-rebased", {
        seedId,
        runId,
        reason: "pre-dispatch",
        from: localHead,
        to: remoteHead,
        targetBranch,
      }, runId);

      return { rebased: true, autoRebasePerformed: true };
    } else {
      // Rebase failed with conflicts
      const conflictList = rebaseResult.conflictingFiles ?? [];
      const errorMsg = `Rebase failed with conflicts: ${conflictList.join(", ") || "unknown conflicts"}`;

      store.logEvent(projectId, "worktree-rebase-failed", {
        seedId,
        runId,
        reason: "pre-dispatch",
        from: localHead,
        to: remoteHead,
        targetBranch,
        conflictingFiles: conflictList,
        error: errorMsg,
      }, runId);

      if (failOnConflict) {
        throw new Error(errorMsg);
      }

      return {
        rebased: false,
        autoRebasePerformed: true,
        error: errorMsg,
        conflictingFiles: conflictList,
      };
    }
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);

    // Log the failure event
    store.logEvent(projectId, "worktree-rebase-failed", {
      seedId,
      runId,
      reason: "pre-dispatch",
      from: localHead,
      to: remoteHead,
      targetBranch,
      error: msg,
    }, runId);

    // Check if it's a conflict error (from rebase()) vs something else
    if (msg.includes("conflict") || msg.includes("CONFLICT")) {
      if (failOnConflict) {
        throw new Error(`Rebase conflict: ${msg}`);
      }
      return {
        rebased: false,
        autoRebasePerformed: true,
        error: `Rebase conflict: ${msg}`,
      };
    }

    // Non-conflict error (network, permissions, etc.) — still throw
    throw new Error(`Rebase failed: ${msg}`);
  }
}

/**
 * Detect whether a worktree is stale without performing any changes.
 *
 * Returns stale state information but does NOT trigger auto-rebase.
 * Useful for pre-flight checks or when you want to know the state
 * before deciding whether to rebase.
 *
 * @param vcs - VCS backend instance
 * @param worktreePath - Absolute path to the worktree
 * @param targetBranch - Target branch name
 * @returns StaleDetectionResult with isStale flag
 */
export async function detectStaleWorktree(
  vcs: VcsBackend,
  worktreePath: string,
  targetBranch: string,
): Promise<StaleDetectionResult> {
  let localHead: string;
  try {
    localHead = await vcs.getHeadId(worktreePath);
  } catch {
    // No commits — not stale, just new
    return {
      isStale: false,
      localHead: "",
      remoteHead: "",
      targetBranch,
    };
  }

  try {
    await vcs.fetch(worktreePath);
  } catch {
    // Fetch failures are non-fatal
  }

  let remoteHead: string;
  try {
    remoteHead = await vcs.resolveRef(worktreePath, `origin/${targetBranch}`);
  } catch {
    // origin/targetBranch doesn't exist — not stale
    return {
      isStale: false,
      localHead,
      remoteHead: "",
      targetBranch,
    };
  }

  return {
    isStale: localHead !== remoteHead,
    localHead,
    remoteHead,
    targetBranch,
  };
}

/**
 * Check if a worktree has uncommitted changes.
 * Used before auto-rebase to warn the operator.
 *
 * @param vcs - VCS backend instance
 * @param worktreePath - Absolute path to the worktree
 * @returns true if the worktree has uncommitted changes
 */
export async function hasUncommittedChanges(
  vcs: VcsBackend,
  worktreePath: string,
): Promise<boolean> {
  try {
    const status = await vcs.status(worktreePath);
    return status.trim().length > 0;
  } catch {
    return false;
  }
}

/**
 * Get a summary of the worktree state for logging.
 *
 * Returns a human-readable string describing the worktree status.
 */
export async function getWorktreeStatusSummary(
  vcs: VcsBackend,
  worktreePath: string,
  targetBranch: string,
): Promise<string> {
  try {
    const localHead = await vcs.getHeadId(worktreePath);
    await vcs.fetch(worktreePath);
    const remoteHead = await vcs.resolveRef(worktreePath, `origin/${targetBranch}`);
    const currentBranch = await vcs.getCurrentBranch(worktreePath);
    const status = await vcs.status(worktreePath);
    const hasChanges = status.trim().length > 0;

    const staleStatus = localHead === remoteHead ? "up-to-date" : "stale";
    const changeStatus = hasChanges ? "with uncommitted changes" : "clean";

    return `${currentBranch} (${localHead.slice(0, 8)}) vs origin/${targetBranch} (${remoteHead.slice(0, 8)}) — ${staleStatus}, ${changeStatus}`;
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    return `unknown state: ${msg}`;
  }
}