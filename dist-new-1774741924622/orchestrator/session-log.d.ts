/**
 * Session log generation for pipeline-executed seeds.
 *
 * The /ensemble:sessionlog skill is only available in interactive Claude Code
 * (human-invoked), not through the Anthropic SDK's query() method. This module
 * provides a direct TypeScript replacement that the pipeline calls automatically
 * at completion, accumulating the same data that /ensemble:sessionlog would
 * otherwise capture interactively.
 *
 * Output: SessionLogs/session-DDMMYY-HH:MM.md in the worktree root.
 * These files are picked up by `git add -A` in finalize() and committed
 * to the branch, so they persist through merge to main.
 */
/**
 * Record of a single pipeline phase execution.
 */
export interface PhaseRecord {
    /** Phase name (e.g., "explorer", "developer", "qa", "reviewer") */
    name: string;
    /** True if this phase was skipped (e.g., --skip-explore or artifact already exists) */
    skipped: boolean;
    /** Whether the phase succeeded (undefined if skipped) */
    success?: boolean;
    /** Cost in USD (undefined if skipped) */
    costUsd?: number;
    /** Number of SDK turns (undefined if skipped) */
    turns?: number;
    /** Error message if the phase failed */
    error?: string;
}
/**
 * Data collected during a pipeline run, used to generate a session log.
 * Populated incrementally by runPipeline() as each phase completes.
 */
export interface SessionLogData {
    /** Seed ID (e.g., "bd-p4y7") */
    seedId: string;
    /** Seed title */
    seedTitle: string;
    /** Seed description */
    seedDescription: string;
    /** Git branch name (e.g., "foreman/bd-p4y7") */
    branchName: string;
    /** Optional project name (basename of project directory) */
    projectName?: string;
    /** Phases executed in order, including skipped and retried phases */
    phases: PhaseRecord[];
    /** Total cost in USD across all phases */
    totalCostUsd: number;
    /** Total SDK turns across all phases */
    totalTurns: number;
    /** Unique files changed during development */
    filesChanged: string[];
    /** Number of developer retries (QA or review feedback loops) */
    devRetries: number;
    /** Final QA verdict ("pass", "fail", or "unknown") */
    qaVerdict: string;
}
/**
 * Format a Date as the session log filename.
 *
 * Convention matches existing SessionLogs/:
 *   session-DDMMYY-HH:MM.md
 *   e.g. session-170326-14:32.md for 2026-03-17 at 14:32
 */
export declare function formatSessionLogFilename(date: Date): string;
/**
 * Generate session log markdown content from pipeline run data.
 *
 * Produces a structured markdown document in the same format as manually-created
 * SessionLogs, capturing phases executed, costs, files changed, and any problems
 * encountered during the pipeline run.
 */
export declare function generateSessionLogContent(data: SessionLogData, date: Date): string;
/**
 * Write a session log to the SessionLogs/ directory.
 *
 * Called just before finalize() in runPipeline() so that `git add -A` picks
 * up the file and includes it in the seed's commit — replacing what the
 * human-only /ensemble:sessionlog skill would otherwise produce.
 *
 * @param basePath  Base directory where SessionLogs/ is created (typically
 *                  the worktree path so the file gets committed to the branch)
 * @param data      Pipeline data accumulated during the run
 * @param date      Timestamp for the filename (defaults to now)
 * @returns         Absolute path to the written session log file
 */
export declare function writeSessionLog(basePath: string, data: SessionLogData, date?: Date): Promise<string>;
//# sourceMappingURL=session-log.d.ts.map