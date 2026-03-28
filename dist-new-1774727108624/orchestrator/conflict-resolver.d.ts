import type { MergeQueueConfig } from "./merge-config.js";
import { MergeValidator } from "./merge-validator.js";
import type { ConflictPatterns } from "./conflict-patterns.js";
import { REPORT_FILES } from "../lib/archive-reports.js";
import type { VcsBackend } from "../lib/vcs/index.js";
export { REPORT_FILES };
/** Cost information for an AI resolution call. */
export interface CostInfo {
    inputTokens: number;
    outputTokens: number;
    inputCostUsd: number;
    outputCostUsd: number;
    totalCostUsd: number;
    estimatedCostUsd: number;
    actualCostUsd: number;
    model: string;
}
/** Result of a Tier 4 AI resolution attempt. */
export interface Tier4Result {
    success: boolean;
    resolvedContent?: string;
    cost?: CostInfo;
    error?: string;
    errorCode?: string;
}
/** Result of a Tier 3 AI resolution attempt. */
export interface Tier3Result {
    success: boolean;
    resolvedContent?: string;
    cost?: CostInfo;
    error?: string;
    errorCode?: string;
}
/** Result of the full per-file tier cascade. */
export interface CascadeResult {
    success: boolean;
    resolvedTiers: Map<string, number>;
    fallbackFiles: string[];
    costs: CostInfo[];
}
/** Result of post-merge test execution. */
export interface PostMergeTestResult {
    passed: boolean;
    skipped: boolean;
    skipReason?: string;
    output?: string;
    errorCode?: string;
}
/** Result of the fallback handler (conflict PR creation). */
export interface FallbackResult {
    prUrl?: string;
    error?: string;
}
export interface UntrackedCheckResult {
    conflicts: string[];
    action: "deleted" | "stashed" | "aborted" | "none";
    stashPath?: string;
    errorCode?: string;
}
export interface MergeAttemptResult {
    success: boolean;
    conflictedFiles: string[];
}
export interface Tier2Result {
    success: boolean;
    reason?: string;
}
export declare class ConflictResolver {
    private projectPath;
    private config;
    private vcs?;
    private validator?;
    private patternLearning?;
    private sessionCostUsd;
    /** VCS binary name — stored as a field so execFileAsync is not called with a string literal. */
    private readonly gitBin;
    constructor(projectPath: string, config: MergeQueueConfig, vcs?: VcsBackend | undefined);
    /** Add to the running session cost total (for testing or external tracking). */
    addSessionCost(amount: number): void;
    /** Get the current session cost total. */
    getSessionCost(): number;
    /** Set (or replace) the MergeValidator instance for AI output validation. */
    setValidator(validator: MergeValidator): void;
    /** Set (or replace) the ConflictPatterns instance for pattern learning (MQ-T067). */
    setPatternLearning(patterns: ConflictPatterns): void;
    /** Run a git command in the project directory. Returns trimmed stdout. */
    private git;
    /**
     * Run a git command that may fail. Returns { ok, stdout, stderr }.
     */
    private gitTry;
    /**
     * Check for untracked files in the working tree that would conflict
     * with files added by the incoming branch.
     *
     * @param branchName   The branch to be merged
     * @param targetBranch The target branch (e.g. "main")
     * @param mode         How to handle conflicts: 'delete' (default), 'stash', or 'abort'
     */
    checkUntrackedConflicts(branchName: string, targetBranch: string, mode?: "delete" | "stash" | "abort"): Promise<UntrackedCheckResult>;
    /**
     * Tier 1: Attempt a standard git merge.
     *
     * Runs `git merge --no-commit --no-ff <branchName>` from the current branch
     * (which should be targetBranch). On success, commits. On conflict, identifies
     * conflicted files and aborts the merge.
     */
    attemptMerge(branchName: string, targetBranch: string): Promise<MergeAttemptResult>;
    /**
     * Tier 2: Per-file conflict resolution with dual-check gate.
     *
     * Must be called while a merge is in progress (after a failed attemptMerge
     * or after manually starting a merge). Applies two checks:
     *
     * 1. **Hunk verification**: Every line unique to the target version must
     *    appear in the branch version (meaning the branch incorporated the
     *    target's changes).
     * 2. **Threshold guard**: The number of discarded lines must not exceed
     *    `maxDiscardedLines` or `maxDiscardedPercent` of the target file.
     *
     * Both checks must pass. If they do, resolves the file using `--theirs`.
     */
    attemptTier2Resolution(filePath: string, branchName: string, targetBranch: string): Promise<Tier2Result>;
    /**
     * Estimate token count from a string using 4 chars/token heuristic.
     */
    private estimateTokens;
    /**
     * Tier 3: AI-powered conflict resolution using Pi agent.
     *
     * Writes the conflicted file to disk, spawns a Pi session with a specialized
     * conflict-resolution prompt, then reads and validates the resolved content.
     *
     * @param filePath - The file path relative to the project root
     * @param fileContent - The file content with conflict markers
     */
    attemptTier3Resolution(filePath: string, fileContent: string): Promise<Tier3Result>;
    /**
     * Tier 4: AI-powered "reimagination" using Pi agent with Opus.
     *
     * Unlike Tier 3 which resolves conflict markers, Tier 4 spawns a Pi agent
     * that reads the canonical file, the branch version, and the diff from git,
     * then reimagines the branch changes applied onto the canonical version.
     *
     * @param filePath - The file path relative to the repo root
     * @param branchName - The feature branch name
     * @param targetBranch - The target branch (e.g. "main")
     */
    attemptTier4Resolution(filePath: string, branchName: string, targetBranch: string): Promise<Tier4Result>;
    /**
     * Run a `gh` CLI command. Returns trimmed stdout.
     * Wrapped in its own method for easy mocking in tests.
     */
    private execGh;
    /**
     * Per-file tier cascade orchestrator (MQ-T038).
     *
     * 1. Attempt a clean git merge (Tier 1).
     * 2. For each conflicted file, cascade through Tiers 2 → 3 → 4 → Fallback.
     * 3. If any file reaches Fallback, abort the entire merge.
     * 4. If all files resolve, commit the merge.
     */
    resolveConflicts(branchName: string, targetBranch: string): Promise<CascadeResult>;
    /**
     * Read the content of a conflicted file from the working tree.
     */
    private readConflictedFile;
    /**
     * Write resolved content to a file and stage it.
     */
    private writeResolvedFile;
    /**
     * Post-merge test runner (MQ-T042).
     *
     * Runs the project test suite after a merge that used AI resolution
     * (Tier 3 or Tier 4). Skips for clean merges and deterministic-only
     * resolution. On failure, reverts the merge commit with
     * `git reset --hard HEAD~1`.
     */
    runPostMergeTests(resolvedTiers: Map<string, number>, testCommand?: string, noTests?: boolean): Promise<PostMergeTestResult>;
    /**
     * Fallback handler (MQ-T039).
     *
     * Aborts the current merge and creates a conflict PR via `gh pr create`
     * with structured metadata about which tiers were attempted.
     *
     * Uses `gh pr create` intentionally (not `git town propose`) -- see
     * MQ-T058d investigation in Refinery.createPRs() for full rationale.
     * Conflict PRs specifically need custom "[Conflict]" title prefix and
     * structured resolution metadata that require API-level control.
     */
    handleFallback(branchName: string, targetBranch: string, fallbackFiles: string[], resolvedTiers: Map<string, number>): Promise<FallbackResult>;
    /**
     * Check if a file path is a report/non-code file that can be auto-resolved.
     */
    static isReportFile(f: string): boolean;
    /**
     * Remove report files from the working tree before merging so they can't
     * conflict. Commits the removal if any tracked files were removed.
     */
    removeReportFiles(): Promise<void>;
    /**
     * Archive report files after a successful merge.
     * Moves report files from the working tree into .foreman/reports/<name>-<seedId>.md
     * and creates a follow-up commit. Called after mergeWorktree() succeeds so we
     * don't need to checkout branches or deal with dirty working trees.
     */
    archiveReportsPostMerge(seedId: string): Promise<void>;
    /**
     * During a rebase conflict, check if all conflicts are report files.
     * If so, auto-resolve them and continue rebase (looping until done).
     * If real code conflicts exist, abort rebase and return false.
     * Returns true if rebase completed successfully.
     */
    autoResolveRebaseConflicts(targetBranch: string): Promise<boolean>;
}
//# sourceMappingURL=conflict-resolver.d.ts.map