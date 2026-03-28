import { Command } from "commander";
import { ForemanStore } from "../../lib/store.js";
import type { Run } from "../../lib/store.js";
export interface WorktreeInfo {
    path: string;
    branch: string;
    head: string;
    seedId: string;
    runStatus: Run["status"] | null;
    runId: string | null;
    createdAt: string | null;
}
export interface CleanResult {
    removed: number;
    errors: string[];
    /** Populated in dry-run mode: the worktrees that would have been removed. */
    wouldRemove?: WorktreeInfo[];
}
/**
 * List all foreman/* worktrees with metadata from the store.
 */
export declare function listForemanWorktrees(projectPath: string, store: Pick<ForemanStore, "getRunsForSeed">): Promise<WorktreeInfo[]>;
/**
 * Clean worktrees based on their run status.
 * - Default: only remove worktrees for completed/merged/failed runs.
 * - `all: true`: remove all foreman worktrees.
 * - `force: true`: use force branch deletion.
 * - `dryRun: true`: show what would be removed without making changes.
 */
export declare function cleanWorktrees(projectPath: string, worktrees: WorktreeInfo[], opts: {
    all: boolean;
    force: boolean;
    dryRun?: boolean;
}): Promise<CleanResult>;
export declare const worktreeCommand: Command;
//# sourceMappingURL=worktree.d.ts.map