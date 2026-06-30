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
import type { EventType } from "../lib/store.js";
import type { VcsBackend } from "../lib/vcs/index.js";
/** Minimal event logger used by stale worktree checks. */
export interface StaleWorktreeEventStore {
    logEvent(projectId: string, eventType: EventType, details: Record<string, unknown> | string, runId?: string): Promise<void> | void;
}
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
    /** Optional event writer for pre-dispatch stale-worktree observability events. */
    eventWriter?: (eventType: "worktree-rebased" | "worktree-rebase-failed", payload: Record<string, unknown>) => Promise<void> | void;
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
export declare function checkAndRebaseStaleWorktree(vcs: VcsBackend, worktreePath: string, targetBranch: string, store: StaleWorktreeEventStore, projectId: string, runId: string, seedId: string, opts?: StaleWorktreeCheckOptions): Promise<StaleWorktreeCheckResult>;
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
export declare function detectStaleWorktree(vcs: VcsBackend, worktreePath: string, targetBranch: string): Promise<StaleDetectionResult>;
/**
 * Check if a worktree has uncommitted changes.
 * Used before auto-rebase to warn the operator.
 *
 * @param vcs - VCS backend instance
 * @param worktreePath - Absolute path to the worktree
 * @returns true if the worktree has uncommitted changes
 */
export declare function hasUncommittedChanges(vcs: VcsBackend, worktreePath: string): Promise<boolean>;
/**
 * Get a summary of the worktree state for logging.
 *
 * Returns a human-readable string describing the worktree status.
 */
export declare function getWorktreeStatusSummary(vcs: VcsBackend, worktreePath: string, targetBranch: string): Promise<string>;
//# sourceMappingURL=stale-worktree-check.d.ts.map