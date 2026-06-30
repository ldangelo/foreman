import type { Run } from "../lib/store.js";
import type { ITaskClient } from "../lib/task-client.js";
import type { VcsBackend } from "../lib/vcs/interface.js";
import type { MonitorReport } from "./types.js";
export interface HungSessionInfo {
    runId: string;
    seedId: string;
    worktreePath: string | null;
    currentPhase: string | null;
    lastActivity: string | null;
    staleMins: number;
}
export interface HungSessionReport {
    hung: HungSessionInfo[];
    checked: number;
}
interface MonitorStore {
    getActiveRuns(projectId?: string): Promise<Run[]>;
    getRun?(runId: string): Promise<Run | null> | Run | null;
    updateRun(runId: string, updates: Partial<Pick<Run, "status" | "worktree_path" | "started_at" | "completed_at">>): Promise<void>;
    logEvent(projectId: string, eventType: "complete" | "stuck" | "fail" | "recover", data: Record<string, unknown>, runId?: string): Promise<void>;
    getRunProgress(runId: string): Promise<import("../lib/store.js").RunProgress | null>;
    getRunEvents(runId: string, eventType?: "recover"): Promise<Array<{
        id: string;
        event_type: string;
        data: string;
        created_at: string;
    }>>;
}
/**
 * Return true when a worktree at `worktreePath` contains at least one
 * completed-phase artifact, indicating partial pipeline progress that
 * should be preserved rather than wiped on recovery.
 */
export declare function worktreeHasProgress(worktreePath: string): boolean;
/**
 * Returns true when an error from taskClient.show() indicates the issue
 * simply hasn't been created / synced yet (migration transient state).
 *
 * Recognises:
 *   - "not found" (case-insensitive substring)
 *   - "404"
 */
export declare function isNotFoundError(err: unknown): boolean;
export declare class Monitor {
    private store;
    private taskClient;
    private projectPath;
    private vcsBackend?;
    constructor(store: MonitorStore, taskClient: ITaskClient, projectPath: string, vcsBackend?: VcsBackend | undefined);
    private getVcsBackend;
    /**
     * Check all active runs and categorise them by status.
     * Updates the store for any status transitions detected.
     */
    checkAll(opts?: {
        stuckTimeoutMinutes?: number;
        projectId?: string;
    }): Promise<MonitorReport>;
    /**
     * Detect sessions that appear to be hung waiting on a Pi SDK API response.
     *
     * A session is considered hung when its `lastActivity` timestamp in run progress
     * has not been updated for more than `hangThresholdMinutes` (default 10 min).
     * This catches cases where the Pi SDK awaits an API response that never returns
     * (rate limits, network timeouts) — the process stays alive at 0% CPU.
     *
     * Detected hung runs are marked as `stuck` in the store.
     */
    detectHungSessions(opts?: {
        hangThresholdMinutes?: number;
        projectId?: string;
    }): Promise<HungSessionReport>;
    /**
     * Attempt to recover a stuck run by killing the worktree and re-creating it.
     * Returns true if recovered (re-queued as pending), false if max retries exceeded.
     */
    recoverStuck(run: Run, maxRetries?: number): Promise<boolean>;
}
export {};
//# sourceMappingURL=monitor.d.ts.map