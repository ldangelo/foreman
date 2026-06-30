/**
 * Refinery Agent — Agentic Merge Queue Processing
 *
 * Replaces the legacy refinery script (~1500 lines, <5% success) with an agent
 * that reads PRs, fixes mechanical failures, builds, tests, and merges.
 *
 * Target: ~50 lines of agent code achieving 90%+ success rate.
 */
import type { VcsBackend } from "../lib/vcs/index.js";
import type { MergeQueueEntry } from "./merge-queue.js";
import { type Run } from "../lib/store.js";
type Awaitable<T> = T | Promise<T>;
export interface RefineryAgentConfig {
    pollIntervalMs: number;
    maxFixIterations: number;
    projectPath: string;
    logDir: string;
    systemPromptPath?: string;
    /** Model for the fix agent (default: sonnet) */
    model?: string;
}
export interface RunLookup {
    getRun(id: string): Awaitable<Run | null>;
}
export interface AgentResult {
    success: boolean;
    action: "merged" | "escalated" | "skipped" | "error";
    logPath: string;
    message?: string;
    costUsd?: number;
}
interface RefineryQueue {
    list(status?: "pending" | "merging" | "merged" | "conflict" | "failed"): Promise<MergeQueueEntry[]>;
    dequeue(): Promise<MergeQueueEntry | null>;
    updateStatus(id: number, status: "pending" | "merging" | "merged" | "conflict" | "failed", extra?: {
        resolvedTier?: number;
        error?: string;
        completedAt?: string;
        lastAttemptedAt?: string;
        retryCount?: number;
    }): Promise<void>;
    resetForRetry(seedId: string): Promise<boolean>;
}
export declare function wrapLocalRefineryQueue(queue: {
    list: (status?: "pending" | "merging" | "merged" | "conflict" | "failed") => MergeQueueEntry[];
    dequeue: () => MergeQueueEntry | null;
    updateStatus: (id: number, status: "pending" | "merging" | "merged" | "conflict" | "failed", extra?: {
        resolvedTier?: number;
        error?: string;
        completedAt?: string;
        lastAttemptedAt?: string;
        retryCount?: number;
    }) => void;
    resetForRetry: (seedId: string) => boolean;
}): RefineryQueue;
export declare class RefineryAgent {
    private mergeQueue;
    private vcsBackend;
    private projectPath;
    private config;
    private running;
    private systemPrompt;
    private runLookup;
    private mailClient;
    private mailInitialized;
    constructor(mergeQueue: RefineryQueue, vcsBackend: VcsBackend, projectPath: string, config?: Partial<RefineryAgentConfig>, runLookup?: RunLookup);
    /**
     * Ensure the mail client is initialized for this project.
     * Safe to call multiple times.
     */
    private ensureMailClient;
    /**
     * Start the agent daemon loop.
     */
    start(): Promise<void>;
    /**
     * Stop the agent daemon.
     */
    stop(): void;
    /**
     * Process the merge queue once (for --once mode).
     */
    processOnce(): Promise<AgentResult[]>;
    private loadSystemPrompt;
    /**
     * Poll and process pending queue entries.
     */
    private processQueue;
    /**
     * Process a single queue entry.
     */
    private processEntry;
    /**
     * Read PR state using gh commands.
     */
    private readPrState;
    /**
     * Check if CI status checks are passing.
     */
    private checkCiStatus;
    /**
     * Run the agent to fix issues and merge.
     *
     * Uses the Pi SDK to run an agent session that:
     * 1. Reads the PR diff and identifies mechanical failures
     * 2. Applies fixes (type errors, missing imports, wiring gaps)
     * 3. Runs build
     * 4. Runs tests
     * 5. Merges if all pass, escalates if not
     */
    private runAgent;
    /**
     * Build the task prompt for the fix agent.
     */
    private buildAgentTaskPrompt;
    /**
     * Build the tool array for the agent session.
     * Uses the worktree path as the agent's cwd.
     */
    private buildTools;
    /**
     * Check if the build passes in the worktree.
     */
    private checkBuildOk;
    /**
     * Check if tests pass in the worktree.
     */
    private checkTestsOk;
    /**
     * Commit all changes in the worktree and push to origin.
     * Handles dirty state by stashing, committing, then restoring.
     */
    private commitAndPush;
    /**
     * Merge the branch via gh pr merge.
     * Uses --squash only; does NOT auto-delete the branch on failure.
     */
    private mergeBranch;
    /**
     * Create a manual PR for escalation when the agent can't auto-fix.
     */
    private escalate;
    private ensureLogDir;
    private logAction;
    private sleep;
}
export {};
//# sourceMappingURL=refinery-agent.d.ts.map