import { existsSync } from "node:fs";
import { join } from "node:path";
import { removeWorktree, createWorktree } from "../lib/git.js";
import { archiveWorktreeReports } from "../lib/archive-reports.js";
import { PIPELINE_LIMITS } from "../lib/config.js";
/**
 * Pipeline artifact filenames written by each phase.
 * Used to detect which phases have already completed when recovering a stuck run.
 */
const PIPELINE_ARTIFACTS = [
    "EXPLORER_REPORT.md",
    "DEVELOPER_REPORT.md",
    "QA_REPORT.md",
    "REVIEW.md",
];
/**
 * Return true when a worktree at `worktreePath` contains at least one
 * completed-phase artifact, indicating partial pipeline progress that
 * should be preserved rather than wiped on recovery.
 */
export function worktreeHasProgress(worktreePath) {
    return PIPELINE_ARTIFACTS.some((artifact) => existsSync(join(worktreePath, artifact)));
}
// ── Helpers ───────────────────────────────────────────────────────────────
/**
 * Returns true when an error from taskClient.show() indicates the issue
 * simply hasn't been created / synced yet (migration transient state).
 *
 * Recognises:
 *   - "not found" (case-insensitive substring)
 *   - "404"
 */
export function isNotFoundError(err) {
    const msg = err instanceof Error ? err.message : String(err);
    const lower = msg.toLowerCase();
    return lower.includes("not found") || lower.includes("404");
}
// ── Monitor ──────────────────────────────────────────────────────────────
export class Monitor {
    store;
    taskClient;
    projectPath;
    constructor(store, taskClient, projectPath) {
        this.store = store;
        this.taskClient = taskClient;
        this.projectPath = projectPath;
    }
    /**
     * Check all active runs and categorise them by status.
     * Updates the store for any status transitions detected.
     */
    async checkAll(opts) {
        const stuckTimeout = opts?.stuckTimeoutMinutes ?? PIPELINE_LIMITS.stuckDetectionMinutes;
        const activeRuns = this.store.getActiveRuns(opts?.projectId);
        const report = {
            completed: [],
            stuck: [],
            active: [],
            failed: [],
        };
        const now = Date.now();
        for (const run of activeRuns) {
            try {
                // ── Completion check via taskClient.show() ────────────────────
                let issueStatus = null;
                try {
                    const issueDetail = await this.taskClient.show(run.seed_id);
                    issueStatus = issueDetail.status;
                }
                catch (showErr) {
                    if (isNotFoundError(showErr)) {
                        // Transient during migration: issue not yet visible in new backend.
                        // Log a warning but continue to the stuck-timeout check below.
                        console.warn(`[monitor] transient show() error for ${run.seed_id}: ` +
                            `${showErr instanceof Error ? showErr.message : String(showErr)}`);
                    }
                    else {
                        // Non-transient error — re-throw so the outer catch marks this run failed.
                        throw showErr;
                    }
                }
                if (issueStatus === "closed" || issueStatus === "completed") {
                    // Agent finished — mark run as completed
                    this.store.updateRun(run.id, {
                        status: "completed",
                        completed_at: new Date().toISOString(),
                    });
                    this.store.logEvent(run.project_id, "complete", { seedId: run.seed_id, detectedBy: "monitor" }, run.id);
                    report.completed.push({ ...run, status: "completed" });
                    continue;
                }
                // Check for stuck agents
                if (run.started_at) {
                    const startedAt = new Date(run.started_at).getTime();
                    const elapsedMinutes = (now - startedAt) / (1000 * 60);
                    if (elapsedMinutes > stuckTimeout) {
                        this.store.updateRun(run.id, { status: "stuck" });
                        this.store.logEvent(run.project_id, "stuck", { seedId: run.seed_id, elapsedMinutes: Math.round(elapsedMinutes) }, run.id);
                        report.stuck.push({ ...run, status: "stuck" });
                        continue;
                    }
                }
                // Still actively running
                report.active.push(run);
            }
            catch (err) {
                const message = err instanceof Error ? err.message : String(err);
                this.store.updateRun(run.id, {
                    status: "failed",
                    completed_at: new Date().toISOString(),
                });
                this.store.logEvent(run.project_id, "fail", { seedId: run.seed_id, error: message }, run.id);
                report.failed.push({ ...run, status: "failed" });
            }
        }
        return report;
    }
    /**
     * Attempt to recover a stuck run by killing the worktree and re-creating it.
     * Returns true if recovered (re-queued as pending), false if max retries exceeded.
     */
    async recoverStuck(run, maxRetries = PIPELINE_LIMITS.maxRecoveryRetries) {
        // Count previous recovery attempts from the events log
        const recoverEvents = this.store.getRunEvents(run.id, "recover");
        const retryCount = recoverEvents.length;
        if (retryCount >= maxRetries) {
            this.store.updateRun(run.id, {
                status: "failed",
                completed_at: new Date().toISOString(),
            });
            this.store.logEvent(run.project_id, "fail", { seedId: run.seed_id, reason: `Max retries (${maxRetries}) exceeded` }, run.id);
            return false;
        }
        // If the worktree has partial pipeline progress (artifact files from completed phases),
        // preserve it so the pipeline can skip already-completed phases on re-dispatch.
        // Only remove and recreate the worktree when there is no prior progress to resume.
        const hasProgress = run.worktree_path ? worktreeHasProgress(run.worktree_path) : false;
        if (hasProgress && run.worktree_path) {
            // Preserve the worktree — artifact-based phase-skipping in runPipeline will handle
            // resuming from the correct phase when the run is re-dispatched.
            this.store.updateRun(run.id, {
                status: "pending",
                started_at: null,
                completed_at: null,
            });
            this.store.logEvent(run.project_id, "recover", {
                seedId: run.seed_id,
                attempt: retryCount + 1,
                maxRetries,
                worktreePreserved: true,
                worktreePath: run.worktree_path,
            }, run.id);
            return true;
        }
        // No prior progress — remove the old worktree and recreate it fresh.
        if (run.worktree_path) {
            try {
                await archiveWorktreeReports(this.projectPath, run.worktree_path, run.seed_id);
            }
            catch {
                // Archive is best-effort — don't block worktree removal
            }
            try {
                await removeWorktree(this.projectPath, run.worktree_path);
            }
            catch {
                // Worktree may already be gone — that's fine
            }
        }
        // Recreate worktree
        try {
            const { worktreePath } = await createWorktree(this.projectPath, run.seed_id);
            this.store.updateRun(run.id, {
                status: "pending",
                worktree_path: worktreePath,
                started_at: null,
                completed_at: null,
            });
            this.store.logEvent(run.project_id, "recover", { seedId: run.seed_id, attempt: retryCount + 1, maxRetries, worktreePreserved: false }, run.id);
            return true;
        }
        catch (err) {
            const message = err instanceof Error ? err.message : String(err);
            this.store.updateRun(run.id, {
                status: "failed",
                completed_at: new Date().toISOString(),
            });
            this.store.logEvent(run.project_id, "fail", { seedId: run.seed_id, reason: `Recovery failed: ${message}` }, run.id);
            return false;
        }
    }
}
//# sourceMappingURL=monitor.js.map