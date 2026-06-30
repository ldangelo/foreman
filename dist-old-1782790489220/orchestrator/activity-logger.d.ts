/**
 * Activity logger — Generates ACTIVITY_LOG.json for self-documenting commits.
 *
 * Tracks phase execution data throughout a pipeline run and produces a
 * machine-readable activity log that is committed alongside code changes.
 *
 * This enables operators to understand what happened in a pipeline run
 * by inspecting the commit (via `git show HEAD:ACTIVITY_LOG.json`) without
 * needing to query the Postgres events table.
 *
 * @module src/orchestrator/activity-logger
 */
import type { VcsBackend } from "../lib/vcs/index.js";
/**
 * Record of a single pipeline phase execution.
 * Extended from session-log.ts PhaseRecord to include observability fields.
 */
export interface PhaseRecord {
    /** Phase name (e.g., "explorer", "developer", "qa") */
    name: string;
    /** Execution surface used for this phase. */
    phaseType?: "prompt" | "command" | "bash" | "builtin";
    /** True if this phase was skipped */
    skipped: boolean;
    /** Whether the phase succeeded */
    success?: boolean;
    /** Cost in USD */
    costUsd?: number;
    /** Number of SDK turns */
    turns?: number;
    /** Error message if phase failed */
    error?: string;
    /** ISO 8601 timestamp when phase started */
    startedAt?: string;
    /** ISO 8601 timestamp when phase completed */
    completedAt?: string;
    /** Duration in seconds */
    durationSeconds?: number;
    /** Number of tool calls */
    toolCalls?: number;
    /** Tool call breakdown by tool name */
    toolBreakdown?: Record<string, number>;
    /** Files changed during this phase */
    filesChanged?: string[];
    /** Edit counts per file */
    editsByFile?: Record<string, number>;
    /** Commands run (for bash phases) */
    commandsRun?: string[];
    /** Expected artifact filename for this phase. */
    artifactExpected?: string;
    /** Whether the expected artifact existed when the phase finished. */
    artifactPresent?: boolean;
    /** Relative JSON trace path for this phase. */
    traceFile?: string;
    /** Relative markdown trace path for this phase. */
    traceMarkdownFile?: string;
    /** Observability warnings recorded for this phase. */
    phaseWarnings?: string[];
    /** Heuristic for whether a command workflow was actually honored. */
    commandHonored?: boolean;
    /** Workflow name used for this phase. */
    workflowName?: string;
    /** Workflow YAML source path used for this phase. */
    workflowPath?: string;
    /** Verdict: pass, fail, skipped, unknown */
    verdict?: "pass" | "fail" | "skipped" | "unknown";
    /** Model used for this phase */
    model?: string;
}
/**
 * Commit information for activity log.
 */
export interface CommitInfo {
    /** Commit hash (short form for display) */
    hash: string;
    /** Commit message */
    message: string;
    /** ISO 8601 timestamp */
    timestamp: string;
    /** Author name */
    author?: string;
}
/**
 * Machine-readable activity log structure.
 * Written to ACTIVITY_LOG.json and committed with every branch.
 */
export interface ActivityLog {
    /** Seed/bead ID (e.g., "bd-ytzv") */
    seedId: string;
    /** Run ID (e.g., UUID) */
    runId: string;
    /** Phase execution records in order */
    phases: PhaseRecord[];
    /** Total cost in USD across all phases */
    totalCostUsd: number;
    /** Total SDK turns across all phases */
    totalTurns: number;
    /** Total tool calls across all phases */
    totalToolCalls: number;
    /** Deduplicated union of all files changed across phases */
    filesChangedTotal: string[];
    /** Commits made during this run */
    commits: CommitInfo[];
    /** Warnings detected during the run */
    warnings: string[];
    /** Number of developer retries (QA or review feedback loops) */
    retryLoops: number;
    /** ISO 8601 timestamp when this log was generated */
    generatedAt: string;
    /** Git diff stat output (when includeGitDiffStat is true) */
    gitDiffStat?: string;
    /** Total duration in seconds across all phases */
    totalDurationSeconds?: number;
}
/**
 * Options for generating an activity log.
 */
export interface GenerateActivityLogOptions {
    /** Absolute path to the worktree */
    worktreePath: string;
    /** Run ID */
    runId: string;
    /** Seed/bead ID */
    seedId: string;
    /** Phase records accumulated during pipeline execution */
    phases: PhaseRecord[];
    /** VCS backend for computing git diff and commit info */
    vcs: VcsBackend;
    /** Target branch for diff computation (e.g., "main", "dev") */
    targetBranch: string;
    /** Whether to include git diff stat output */
    includeGitDiffStat?: boolean;
}
/**
 * Compute the deduplicated union of all files changed across phases.
 */
export declare function computeFilesChangedTotal(phases: PhaseRecord[]): string[];
/**
 * Count the number of developer retries (developer phase reruns due to
 * QA or reviewer feedback).
 */
export declare function countRetries(phases: PhaseRecord[]): number;
/**
 * Detect warnings from phase records.
 *
 * Warnings include:
 * - Guardrail vetoes
 * - Retry loops (multiple developer retries)
 * - Stale worktree events
 * - Phase failures
 */
export declare function detectWarnings(phases: PhaseRecord[]): string[];
/**
 * Generate an ACTIVITY_LOG.json file in the worktree.
 *
 * Reads phase records accumulated during pipeline execution, computes
 * totals and warnings, and writes a machine-readable JSON file that
 * is committed with every branch.
 *
 * @param opts - Generation options
 */
export declare function generateActivityLog(opts: GenerateActivityLogOptions): Promise<void>;
/**
 * Create an initial PhaseRecord for a new phase.
 * Call this at phase start, then update with results at phase end.
 */
export declare function createPhaseRecord(name: string, model?: string, extra?: Pick<PhaseRecord, "phaseType" | "commandsRun" | "artifactExpected" | "workflowName" | "workflowPath">): PhaseRecord;
/**
 * Finalize a PhaseRecord with completion data.
 * Call this at phase end with the phase result.
 */
export declare function finalizePhaseRecord(record: PhaseRecord, result: {
    success: boolean;
    costUsd: number;
    turns: number;
    tokensIn?: number;
    tokensOut?: number;
    error?: string;
    outputText?: string;
    toolCalls?: number;
    toolBreakdown?: Record<string, number>;
    filesChanged?: string[];
    editsByFile?: Record<string, number>;
    traceFile?: string;
    traceMarkdownFile?: string;
    traceWarnings?: string[];
    commandHonored?: boolean;
    workflowName?: string;
    workflowPath?: string;
}): PhaseRecord;
/**
 * Write an incremental pipeline report after each phase completes.
 * Commits phase results as they finish so traceability is available in real-time.
 */
export declare function writeIncrementalPipelineReport(opts: {
    worktreePath: string;
    seedId: string;
    runId: string;
    completedPhases: PhaseRecord[];
    targetBranch?: string;
    vcsBranchName?: string;
}): Promise<void>;
//# sourceMappingURL=activity-logger.d.ts.map