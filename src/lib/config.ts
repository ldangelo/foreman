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

// ── Helpers ──────────────────────────────────────────────────────────────

/**
 * Read a budget value from an environment variable.
 * Returns the default if the variable is not set.
 * Throws if the variable is set to an invalid value.
 */
export function readBudgetFromEnv(envName: string, defaultValue: number): number {
  const envValue = process.env[envName];
  if (envValue === undefined || envValue === "") {
    return defaultValue;
  }
  const parsed = parseFloat(envValue);
  if (isNaN(parsed) || parsed <= 0) {
    throw new Error(
      `Invalid budget value for ${envName}: "${envValue}". Must be a positive number.`,
    );
  }
  return parsed;
}

function envInt(name: string, defaultValue: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return defaultValue;
  const parsed = parseInt(raw, 10);
  if (isNaN(parsed) || parsed <= 0) {
    console.warn(`[foreman] Warning: invalid value for ${name}="${raw}", using default ${defaultValue}`);
    return defaultValue;
  }
  return parsed;
}

/**
 * Like envInt but accepts zero — for parameters where 0 is a valid choice
 * (e.g. disabling retries entirely in CI).
 */
function envNonNegativeInt(name: string, defaultValue: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return defaultValue;
  const parsed = parseInt(raw, 10);
  if (isNaN(parsed) || parsed < 0) {
    console.warn(`[foreman] Warning: invalid value for ${name}="${raw}", using default ${defaultValue}`);
    return defaultValue;
  }
  return parsed;
}

// ── Budget getters (USD) ─────────────────────────────────────────────────

/** Budget for the Explorer phase (default: $1.00, uses Haiku model). */
export function getExplorerBudget(): number {
  return readBudgetFromEnv("FOREMAN_EXPLORER_BUDGET_USD", 1.00);
}

/** Budget for the Developer phase (default: $5.00, uses Sonnet model). */
export function getDeveloperBudget(): number {
  return readBudgetFromEnv("FOREMAN_DEVELOPER_BUDGET_USD", 5.00);
}

/** Budget for the QA phase (default: $3.00, uses Sonnet model). */
export function getQaBudget(): number {
  return readBudgetFromEnv("FOREMAN_QA_BUDGET_USD", 3.00);
}

/** Budget for the Reviewer phase (default: $2.00, uses Sonnet model). */
export function getReviewerBudget(): number {
  return readBudgetFromEnv("FOREMAN_REVIEWER_BUDGET_USD", 2.00);
}

/** Budget for one-off plan-step SDK queries (default: $3.00). */
export function getPlanStepBudget(): number {
  return readBudgetFromEnv("FOREMAN_PLAN_STEP_BUDGET_USD", 3.00);
}

/** Budget for the Sentinel phase (default: $2.00, uses Sonnet model). */
export function getSentinelBudget(): number {
  return readBudgetFromEnv("FOREMAN_SENTINEL_BUDGET_USD", 2.00);
}

/** Budget for the session-log SDK query (default: $0.50, uses Haiku model). */
export function getSessionLogBudget(): number {
  return readBudgetFromEnv("FOREMAN_SESSION_LOG_BUDGET_USD", 0.50);
}

// ── Timeout values (milliseconds) ────────────────────────────────────────

export const PIPELINE_TIMEOUTS = {
  /** Interval for flushing progress to the store in single-agent mode */
  progressFlushMs: envInt("FOREMAN_PROGRESS_FLUSH_MS", 2_000),
  /** Timeout for git add/commit/push during pipeline finalization */
  gitOperationMs: envInt("FOREMAN_GIT_OPERATION_TIMEOUT_MS", 30_000),
  /** Timeout for resetting a bead back to open after stuck/failed */
  beadClosureMs: envInt("FOREMAN_BEAD_CLOSURE_TIMEOUT_MS", 10_000),
  /** Timeout for running the test suite after a merge */
  testExecutionMs: envInt("FOREMAN_TEST_EXECUTION_TIMEOUT_MS", 5 * 60 * 1000),
  /** Timeout for running tests in the sentinel (default: 10 minutes) */
  sentinelTestMs: envInt("FOREMAN_SENTINEL_TEST_TIMEOUT_MS", 10 * 60 * 1000),
  /** Timeout for the LLM TRD decomposition call */
  llmDecomposeMs: envInt("FOREMAN_LLM_DECOMPOSE_TIMEOUT_MS", 600_000),
  /** Watch-UI polling interval */
  monitorPollMs: envInt("FOREMAN_MONITOR_POLL_MS", 3_000),
  /** Stale pending-run threshold in hours (for doctor check) */
  staleRunHours: envInt("FOREMAN_STALE_RUN_HOURS", 24),
} as const;

// ── Retry / concurrency limits ────────────────────────────────────────────

export const PIPELINE_LIMITS = {
  /** How many times the developer phase may be re-run after QA or review failure */
  maxDevRetries: envNonNegativeInt("FOREMAN_MAX_DEV_RETRIES", 2),
  /** Maximum number of stuck-run recovery attempts before marking as failed */
  maxRecoveryRetries: envNonNegativeInt("FOREMAN_MAX_RECOVERY_RETRIES", 3),
  /** Minutes of inactivity before a running agent is considered stuck */
  stuckDetectionMinutes: envInt("FOREMAN_STUCK_DETECTION_MINUTES", 15),
} as const;

// ── Buffer sizes ──────────────────────────────────────────────────────────

export const PIPELINE_BUFFERS = {
  /** maxBuffer for execFile calls to git, gh, and claude CLI (10 MB default) */
  maxBufferBytes: envInt("FOREMAN_BUFFER_SIZE_BYTES", 10 * 1024 * 1024),
} as const;
