/**
 * Report files that agents produce in the worktree root.
 * These are archived before worktree deletion.
 */
export declare const REPORT_FILES: string[];
/**
 * Archive report files from a worktree into .foreman/reports/<seedId>/
 * before the worktree is deleted. Best-effort: errors are logged but not thrown.
 *
 * Files are copied (not moved) since the worktree directory will be removed
 * entirely by the caller. Any existing archived files are overwritten.
 *
 * @param projectPath - Absolute path to the main git repository root
 * @param worktreePath - Absolute path to the worktree being deleted
 * @param seedId - Seed ID used to name the per-seed archive directory
 * @returns Number of files successfully archived
 */
export declare function archiveWorktreeReports(projectPath: string, worktreePath: string, seedId: string): Promise<number>;
//# sourceMappingURL=archive-reports.d.ts.map