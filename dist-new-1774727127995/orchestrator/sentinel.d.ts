/**
 * SentinelAgent — continuous testing agent for main/master branch.
 *
 * Runs the test suite on the specified branch on a configurable schedule.
 * Records results in SQLite and creates br bug tasks on repeated failures.
 */
import type { ForemanStore } from "../lib/store.js";
import type { BeadsRustClient } from "../lib/beads-rust.js";
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
    private running;
    private timer;
    private consecutiveFailures;
    constructor(store: ForemanStore, seeds: BeadsRustClient, projectId: string, projectPath: string);
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
//# sourceMappingURL=sentinel.d.ts.map