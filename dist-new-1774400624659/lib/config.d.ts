/**
 * Runtime configuration from environment variables with sensible defaults.
 *
 * All values are read from FOREMAN_* environment variables.
 * If a variable is not set, the default value matching the original hardcoded
 * constant is used.
 *
 * Changes to environment variables take effect on the NEXT process start —
 * they are read once at module initialisation and do not hot-reload.
 */
/**
 * Read a budget value from an environment variable.
 * Returns the default if the variable is not set.
 * Throws if the variable is set to an invalid value.
 */
export declare function readBudgetFromEnv(envName: string, defaultValue: number): number;
/** Budget for the Explorer phase (default: $1.00, uses Haiku model). */
export declare function getExplorerBudget(): number;
/** Budget for the Developer phase (default: $5.00, uses Sonnet model). */
export declare function getDeveloperBudget(): number;
/** Budget for the QA phase (default: $3.00, uses Sonnet model). */
export declare function getQaBudget(): number;
/** Budget for the Reviewer phase (default: $2.00, uses Sonnet model). */
export declare function getReviewerBudget(): number;
/** Budget for one-off plan-step SDK queries (default: $3.00). */
export declare function getPlanStepBudget(): number;
/** Budget for the Sentinel phase (default: $2.00, uses Sonnet model). */
export declare function getSentinelBudget(): number;
/** Budget for the session-log SDK query (default: $0.50, uses Haiku model). */
export declare function getSessionLogBudget(): number;
export declare const PIPELINE_TIMEOUTS: {
    /** Interval for flushing progress to the store in single-agent mode */
    readonly progressFlushMs: number;
    /** Timeout for git add/commit/push during pipeline finalization */
    readonly gitOperationMs: number;
    /** Timeout for resetting a bead back to open after stuck/failed */
    readonly beadClosureMs: number;
    /** Timeout for running the test suite after a merge */
    readonly testExecutionMs: number;
    /** Timeout for running tests in the sentinel (default: 10 minutes) */
    readonly sentinelTestMs: number;
    /** Timeout for the LLM TRD decomposition call */
    readonly llmDecomposeMs: number;
    /** Watch-UI polling interval */
    readonly monitorPollMs: number;
    /** Stale pending-run threshold in hours (for doctor check) */
    readonly staleRunHours: number;
    /** Failed-run retention threshold in days; older runs are eligible for cleanup with --fix */
    readonly failedRunRetentionDays: number;
};
export declare const PIPELINE_LIMITS: {
    /** How many times the developer phase may be re-run after QA or review failure */
    readonly maxDevRetries: number;
    /** Maximum number of stuck-run recovery attempts before marking as failed */
    readonly maxRecoveryRetries: number;
    /** Minutes of inactivity before a running agent is considered stuck */
    readonly stuckDetectionMinutes: number;
    /**
     * Number of consecutive empty poll cycles (no tasks dispatched, no active agents)
     * before the dispatch loop exits gracefully in watch mode.
     *
     * At the default polling interval of 3s, 20 cycles = 60 seconds total.
     * Set to 0 to disable the limit (poll indefinitely — legacy behaviour).
     *
     * Override via: FOREMAN_EMPTY_POLL_CYCLES=<n>
     */
    readonly emptyPollCycles: number;
};
/**
 * Exponential backoff configuration for seeds that repeatedly get stuck.
 *
 * When a seed is reset to open after a stuck run, the dispatcher applies
 * this backoff before re-dispatching. This prevents tight retry loops for
 * deterministic failures (e.g. non-fast-forward push errors).
 *
 * Backoff schedule (defaults, maxRetries=3):
 *   1st stuck → wait 60s before retry
 *   2nd stuck → wait 120s before retry
 *   ≥ maxRetries (3) stuck → hard-blocked until window resets (no further delay calc)
 *
 * To enable a 3rd-tier delay (240s) before hard-blocking, set maxRetries=4.
 */
export declare const STUCK_RETRY_CONFIG: {
    /** Number of recent stuck runs before the seed is blocked from dispatch */
    maxRetries: number;
    /** Initial backoff delay in milliseconds after the first stuck run */
    initialDelayMs: number;
    /** Maximum backoff delay in milliseconds */
    maxDelayMs: number;
    /** Multiplier applied to delay on each successive stuck run */
    backoffMultiplier: number;
    /** Time window in milliseconds for counting recent stuck runs (default: 24h) */
    windowMs: number;
};
/**
 * Calculate the required backoff delay in milliseconds for a seed that has
 * been stuck `stuckCount` times recently.
 *
 * Formula: initialDelayMs * backoffMultiplier^(stuckCount - 1), capped at maxDelayMs.
 */
export declare function calculateStuckBackoffMs(stuckCount: number): number;
export declare const PIPELINE_BUFFERS: {
    /** maxBuffer for execFile calls to git, gh, and claude CLI (10 MB default) */
    readonly maxBufferBytes: number;
};
//# sourceMappingURL=config.d.ts.map