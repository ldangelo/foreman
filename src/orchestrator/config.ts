/**
 * Environment variable helpers for runtime configuration.
 *
 * All foreman budget settings can be overridden via environment variables.
 * Defaults match the original hardcoded values so existing deployments
 * continue to work without any configuration changes.
 */

/**
 * Parse a budget value from an environment variable.
 * Returns the default value if the env var is unset, empty, non-numeric, or non-positive.
 *
 * @param varName - Environment variable name (e.g. "FOREMAN_DEVELOPER_MAX_BUDGET_USD")
 * @param defaultValue - Fallback value when env var is absent or invalid
 * @returns A positive number representing the budget in USD
 */
export function getBudgetFromEnv(varName: string, defaultValue: number): number {
  const raw = process.env[varName];
  if (raw === undefined || raw === "") {
    return defaultValue;
  }
  const parsed = parseFloat(raw);
  if (!isFinite(parsed) || parsed <= 0) {
    // Log a warning but fall back gracefully rather than throwing
    console.warn(
      `[foreman] Invalid value for ${varName}="${raw}" (must be a positive number); using default ${defaultValue}`,
    );
    return defaultValue;
  }
  return parsed;
}
