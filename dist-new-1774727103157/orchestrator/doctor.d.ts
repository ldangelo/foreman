import { ForemanStore } from "../lib/store.js";
import type { CheckResult, DoctorReport } from "./types.js";
import type { MergeQueue, ExecFileAsyncFn } from "./merge-queue.js";
import type { ITaskClient } from "../lib/task-client.js";
export declare class Doctor {
    private store;
    private projectPath;
    private mergeQueue?;
    private taskClient?;
    /**
     * Injected execFile-like function used only by `isBranchMerged`.
     * Defaults to the real `execFileAsync`; can be overridden in tests to avoid
     * spawning real git processes.
     */
    private execFn;
    constructor(store: ForemanStore, projectPath: string, mergeQueue?: MergeQueue, taskClient?: ITaskClient, execFn?: ExecFileAsyncFn);
    checkBrBinary(): Promise<CheckResult>;
    checkBvBinary(): Promise<CheckResult>;
    checkGitBinary(): Promise<CheckResult>;
    checkGitTownInstalled(): Promise<CheckResult>;
    checkGitTownMainBranch(): Promise<CheckResult>;
    checkSystem(): Promise<CheckResult[]>;
    /**
     * Check for stale agent log files in ~/.foreman/logs/.
     * Warns when there are many log groups older than 7 days,
     * encouraging the user to run `foreman purge-logs` or `foreman doctor --clean-logs`.
     */
    checkOldLogs(thresholdDays?: number, warnThreshold?: number): Promise<CheckResult>;
    checkDatabaseFile(): Promise<CheckResult>;
    checkProjectRegistered(): Promise<CheckResult>;
    checkBeadsInitialized(): Promise<CheckResult>;
    /**
     * Check that all required prompt files are installed in .foreman/prompts/.
     * With --fix, reinstalls missing prompts from bundled defaults.
     */
    checkPrompts(opts?: {
        fix?: boolean;
        dryRun?: boolean;
    }): Promise<CheckResult>;
    /**
     * Check that required Pi skills are installed in ~/.pi/agent/skills/.
     * With --fix, installs missing skills from bundled defaults.
     */
    checkPiSkills(opts?: {
        fix?: boolean;
        dryRun?: boolean;
    }): Promise<CheckResult>;
    /**
     * Check that all bundled workflow YAML files are installed in .foreman/workflows/.
     * With --fix, reinstalls missing workflow configs from bundled defaults.
     */
    checkWorkflows(opts?: {
        fix?: boolean;
        dryRun?: boolean;
    }): Promise<CheckResult>;
    checkRepository(opts?: {
        fix?: boolean;
        dryRun?: boolean;
    }): Promise<CheckResult[]>;
    checkOrphanedWorktrees(opts?: {
        fix?: boolean;
        dryRun?: boolean;
    }): Promise<CheckResult[]>;
    checkZombieRuns(opts?: {
        fix?: boolean;
        dryRun?: boolean;
    }): Promise<CheckResult[]>;
    checkStalePendingRuns(opts?: {
        fix?: boolean;
        dryRun?: boolean;
    }): Promise<CheckResult>;
    /**
     * Read the beads JSONL and return a Set of seed IDs that are closed.
     * Falls back to an empty set on any read/parse error (non-fatal).
     */
    private getClosedSeedIds;
    /**
     * Check whether `foreman/<seedId>` has already been merged into `defaultBranch`.
     *
     * Uses `git merge-base --is-ancestor` which exits 0 if the branch tip is an
     * ancestor of the default branch (i.e. fully merged).  Returns false on any
     * git error so the caller treats the run as still problematic.
     */
    private isBranchMerged;
    checkFailedStuckRuns(opts?: {
        fix?: boolean;
        dryRun?: boolean;
    }): Promise<CheckResult[]>;
    /**
     * Partition unresolved failed runs into "actionable" (seed has only failed runs)
     * and "historical" (seed has a later completed or merged run — noise from retries).
     */
    private partitionByHistoricalRetry;
    checkRunStateConsistency(opts?: {
        fix?: boolean;
        dryRun?: boolean;
    }): Promise<CheckResult[]>;
    /**
     * Check for bead status drift between SQLite and the br backend.
     *
     * Calls syncBeadStatusOnStartup() to detect (and optionally fix) mismatches
     * between the run status recorded in SQLite and the corresponding seed status
     * in br.  Drift occurs when foreman was interrupted before a br update could
     * complete (e.g. after a crash, token exhaustion, or manual reset).
     *
     * Modes:
     *   - No flags / warn-only: detects mismatches but does not fix them.
     *   - fix=true, dryRun=false: detects and applies fixes via br update.
     *   - dryRun=true: detects mismatches but never applies fixes (dryRun wins over fix).
     *
     * Returns:
     *   pass  — no mismatches detected
     *   warn  — mismatches detected but not fixed (no --fix or dryRun mode)
     *   fixed — mismatches were detected and fixed
     *   fail  — the sync operation itself threw an unexpected error
     *   skip  — no project registered or no task client configured
     */
    checkBeadStatusSync(opts?: {
        fix?: boolean;
        dryRun?: boolean;
        projectPath?: string;
    }): Promise<CheckResult>;
    checkBrRecoveryArtifacts(opts?: {
        fix?: boolean;
        dryRun?: boolean;
    }): Promise<CheckResult>;
    checkBlockedSeeds(): Promise<CheckResult>;
    /**
     * Check for merge queue entries stuck in pending/merging for >24h (MQ-008).
     */
    checkStaleMergeQueueEntries(opts?: {
        fix?: boolean;
        dryRun?: boolean;
    }): Promise<CheckResult>;
    /**
     * Check for duplicate branch entries in the merge queue (MQ-009).
     */
    checkDuplicateMergeQueueEntries(opts?: {
        fix?: boolean;
        dryRun?: boolean;
    }): Promise<CheckResult>;
    /**
     * Check for merge queue entries referencing non-existent runs (MQ-010).
     */
    checkOrphanedMergeQueueEntries(opts?: {
        fix?: boolean;
        dryRun?: boolean;
    }): Promise<CheckResult>;
    /**
     * Check for completed runs that are not present in the merge queue (MQ-011).
     * Detects runs that completed but were never enqueued — e.g. because their
     * branch was deleted before reconciliation ran, or because a system crash
     * prevented reconciliation from completing.
     *
     * When fix=true, calls mergeQueue.reconcile() to enqueue the missing runs.
     */
    checkCompletedRunsNotQueued(opts?: {
        fix?: boolean;
        dryRun?: boolean;
        projectPath?: string;
        execFileFn?: ExecFileAsyncFn | undefined;
    }): Promise<CheckResult>;
    /**
     * Check for merge queue entries stuck in conflict/failed for >1h (MQ-012).
     */
    checkStuckConflictFailedEntries(opts?: {
        fix?: boolean;
        dryRun?: boolean;
    }): Promise<CheckResult>;
    /**
     * Run all merge queue health checks.
     */
    checkMergeQueueHealth(opts?: {
        fix?: boolean;
        dryRun?: boolean;
        projectPath?: string;
    }): Promise<CheckResult[]>;
    /**
     * Check for run records in the legacy global store (~/.foreman/foreman.db) that
     * are absent from the project-local store (.foreman/foreman.db).  This can occur
     * when a run completed before the bd-sjd migration to project-local stores was
     * fully rolled out.
     *
     * With --fix the orphaned records (and their associated costs/events) are copied
     * into the project-local store so that 'foreman merge' can see them.
     */
    checkOrphanedGlobalStoreRuns(opts?: {
        fix?: boolean;
        dryRun?: boolean;
    }): Promise<CheckResult>;
    checkDataIntegrity(opts?: {
        fix?: boolean;
        dryRun?: boolean;
        projectPath?: string;
    }): Promise<CheckResult[]>;
    runAll(opts?: {
        fix?: boolean;
        dryRun?: boolean;
        projectPath?: string;
    }): Promise<DoctorReport>;
}
//# sourceMappingURL=doctor.d.ts.map