/**
 * Runtime configuration from environment variables with sensible defaults.
 *
 * All budget values are read from FOREMAN_*_BUDGET_USD environment variables.
 * If a variable is not set, the default value matching the original hardcoded
 * constant is used. Invalid values (non-numeric, zero, negative) throw at
 * call time so misconfiguration is caught early.
 *
 * Naming convention: FOREMAN_<ROLE>_BUDGET_USD
 */

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
