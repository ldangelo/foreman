import { existsSync } from "node:fs";
import * as fs from "node:fs/promises";
import * as path from "node:path";
/**
 * Report files that agents produce in the worktree root.
 * These are archived before worktree deletion.
 */
export const REPORT_FILES = [
    "EXPLORER_REPORT.md",
    "DEVELOPER_REPORT.md",
    "QA_REPORT.md",
    "REVIEW.md",
    "FINALIZE_REPORT.md",
    "TASK.md",
    "AGENTS.md",
    "BLOCKED.md",
    // Diagnostic artifacts — written by every phase; excluded from commits via
    // `git reset HEAD SESSION_LOG.md RUN_LOG.md` in the finalize prompt, but
    // listed here so the conflict resolver auto-resolves them if they were
    // committed by an older pipeline, and so they are archived before worktree
    // deletion.
    "SESSION_LOG.md",
    "RUN_LOG.md",
];
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
export async function archiveWorktreeReports(projectPath, worktreePath, seedId) {
    const destDir = path.join(projectPath, ".foreman", "reports", seedId);
    let archived = 0;
    try {
        await fs.mkdir(destDir, { recursive: true });
    }
    catch (err) {
        console.warn(`[archive-reports] Failed to create directory ${destDir}: ${err}`);
        return 0;
    }
    for (const report of REPORT_FILES) {
        const src = path.join(worktreePath, report);
        if (existsSync(src)) {
            const dest = path.join(destDir, report);
            try {
                await fs.copyFile(src, dest);
                archived++;
            }
            catch (err) {
                console.warn(`[archive-reports] Failed to copy ${report}: ${err}`);
            }
        }
    }
    return archived;
}
//# sourceMappingURL=archive-reports.js.map