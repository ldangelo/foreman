/**
 * `foreman recover <task-id>` — Autonomous recovery agent for pipeline failures.
 *
 * Gathers all artifacts for a task's pipeline execution (logs, mail messages,
 * reports, run progress, test output, blocked tasks, git log) and invokes an
 * Opus agent to diagnose and autonomously fix common failure modes:
 *
 *   test-failed   — post-merge npm test failures (stale cache, bad expectations, bugs)
 *   stuck         — agent pipeline that stopped responding
 *   stale-blocked — tasks blocked by already-closed dependencies
 *
 * Unlike `foreman debug`, this command is NOT read-only — the agent has write
 * access and will make fixes, commit, and push when appropriate.
 *
 * Note: `<task-id>` is the primary identifier. `--bead` is accepted as a
 * backward-compatible alias.
 */
import { Command } from "commander";
type RecommendedRecovery = "clean-replay-from-main";
interface CleanReplayApplyResult {
    copiedFiles: string[];
    skippedFiles: string[];
}
interface CleanReplayValidationStep {
    name: string;
    success: boolean;
    output: string;
}
interface CleanReplayValidationResult {
    success: boolean;
    steps: CleanReplayValidationStep[];
}
export declare function extractRecommendedRecovery(reports: Record<string, string>): RecommendedRecovery | null;
export declare function parseChangedFiles(statusOutput: string): string[];
export declare function applyCleanReplayChanges(sourceWorktreePath: string, destinationWorkspacePath: string, statusOutput: string): CleanReplayApplyResult;
export declare function validateCleanReplayWorkspace(workspacePath: string): CleanReplayValidationResult;
export declare const recoverCommand: Command;
export {};
//# sourceMappingURL=recover.d.ts.map