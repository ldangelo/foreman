/**
 * SentinelAgent — continuous testing agent for main/master branch.
 *
 * Runs the test suite on the specified branch on a configurable schedule.
 * Records results in Postgres and creates br bug tasks on repeated failures.
 */
import type { Issue } from "../lib/task-client.js";
import type { VcsBackend } from "../lib/vcs/interface.js";
import type { SentinelConfigRow, SentinelRunRow } from "../lib/store.js";
export interface SentinelOptions {
    branch: string;
    testCommand: string;
    intervalMinutes: number;
    failureThreshold: number;
    dryRun?: boolean;
}
export interface SentinelRunResult {
    id: string;
    status: "passed" | "failed" | "error";
    commitHash: string | null;
    output: string;
    durationMs: number;
}
interface SentinelTaskClient {
    list(opts?: {
        status?: string;
        type?: string;
        label?: string;
    }): Promise<Issue[]>;
    create(title: string, opts: {
        type: string;
        priority: string;
        description?: string;
        labels?: string[];
    }): Promise<Issue>;
}
interface SentinelStore {
    close(): void;
    isOpen(): boolean;
    logEvent(projectId: string, eventType: "sentinel-start" | "sentinel-pass" | "sentinel-fail", data: Record<string, unknown>): void | Promise<void>;
    recordSentinelRun(run: Omit<SentinelRunRow, "failure_count"> & {
        failure_count?: number;
    }): void | Promise<void>;
    updateSentinelRun(id: string, updates: Partial<Pick<SentinelRunRow, "status" | "output" | "completed_at" | "failure_count">>): void | Promise<void>;
    upsertSentinelConfig(projectId: string, config: Partial<Omit<SentinelConfigRow, "id" | "project_id" | "created_at" | "updated_at">>): SentinelConfigRow | void | Promise<void>;
    getSentinelConfig(projectId: string): SentinelConfigRow | null | Promise<SentinelConfigRow | null>;
    getSentinelRuns(projectId: string, limit?: number): SentinelRunRow[] | Promise<SentinelRunRow[]>;
}
/**
 * Continuous testing agent that monitors a branch on a schedule.
 *
 * Usage:
 *   const agent = new SentinelAgent(store, seeds, projectId, projectPath);
 *   agent.start(opts, (result) => console.log(result));
 *   // later...
 *   agent.stop();
 */
export declare class SentinelAgent {
    private store;
    private seeds;
    private projectId;
    private projectPath;
    private vcsBackend?;
    private running;
    private timer;
    private consecutiveFailures;
    constructor(store: SentinelStore, seeds: SentinelTaskClient, projectId: string, projectPath: string, vcsBackend?: Pick<VcsBackend, "resolveRef">);
    /**
     * Execute one sentinel run: fetch HEAD commit, run tests, record results.
     */
    runOnce(opts: SentinelOptions): Promise<SentinelRunResult>;
    /**
     * Start the sentinel loop.  Runs immediately, then on each interval.
     * Skips a run if the previous run is still active (queue protection).
     */
    start(opts: SentinelOptions, onResult?: (result: SentinelRunResult) => void): void;
    /** Stop the sentinel loop (in-flight run completes normally). */
    stop(): void;
    isRunning(): boolean;
    private resolveCommit;
    private runTestCommand;
    private createBugTask;
}
export {};
//# sourceMappingURL=sentinel.d.ts.map