/**
 * Guardrails module — Runtime-enforced constraints for Foreman pipeline agents.
 *
 * Provides pre-tool hooks that verify agent operating context before execution,
 * preventing common failure modes like wrong-worktree edits and cross-directory
 * command injection.
 *
 * @module src/orchestrator/guardrails
 */
/**
 * Directory verification guardrail mode.
 *
 * - `auto-correct` — Prepend `cd <expected> &&` to bash commands; fix edit/write
 *                    file paths. Log `guardrail-corrected` event.
 * - `veto`         — Abort the tool call and report via `guardrail-veto` event.
 * - `disabled`     — No checks; pass through immediately.
 */
export type DirectoryGuardrailMode = "auto-correct" | "veto" | "disabled";
/**
 * Guardrail configuration for directory verification.
 */
export interface DirectoryGuardrailConfig {
    /** Guardrail enforcement mode. Default: `auto-correct`. */
    mode?: DirectoryGuardrailMode;
    /**
     * Optional list of allowed path prefixes.
     * When set, the agent's cwd must start with one of these prefixes.
     * Useful for restricting agents to a specific subtree (e.g. only worktrees).
     */
    allowedPaths?: string[];
}
/**
 * Full guardrail configuration for a pipeline run.
 */
export interface GuardrailConfig {
    /** Directory verification guardrail settings. */
    directory?: DirectoryGuardrailConfig;
    /** Expected working directory for this agent session (absolute path). */
    expectedCwd: string;
}
/**
 * Result returned by a guardrail check.
 *
 * - `allowed: true` — The tool call may proceed. If `correctedArgs` is set,
 *                     the tool should use the corrected arguments instead of
 *                     the original ones.
 * - `allowed: false` — The tool call is blocked. The reason is in `reason`.
 */
export interface GuardrailResult {
    allowed: boolean;
    /** Corrected tool arguments (only set when mode is `auto-correct` and correction was needed). */
    correctedArgs?: Record<string, unknown>;
    /** Corrected working directory (only set when mode is `auto-correct` and cwd was corrected). */
    correctedCwd?: string;
    /** Human-readable reason for veto (only set when allowed=false). */
    reason?: string;
    /** Event type to log: "guardrail-veto" or "guardrail-corrected". */
    eventType?: "guardrail-veto" | "guardrail-corrected";
}
/**
 * Create a pre-tool hook for directory verification.
 *
 * Returns a function that wraps tool calls with cwd validation.
 * When cwd matches expected: pass through (no overhead).
 * When cwd is wrong: either correct arguments or veto the call.
 *
 * @param config - Guardrail configuration (expectedCwd required)
 * @param logEvent - Event logging function (writes to store)
 * @param projectId - Foreman project ID
 * @param runId - Current run ID
 * @returns A pre-tool hook function compatible with Pi SDK tool factories
 */
export declare function createDirectoryGuardrail(config: GuardrailConfig, logEvent: (eventType: string, details: Record<string, unknown>) => void, projectId: string, runId: string): (toolName: string, args: Record<string, unknown>, currentCwd: string) => GuardrailResult;
/**
 * Wrap a tool factory function with guardrail enforcement.
 *
 * The wrapped tool intercepts the cwd before the tool executes and runs
 * guardrail validation. If the guardrail vetoes, the tool throws a
 * structured error. If the guardrail corrects, the corrected args are used.
 *
 * @param factory - Original tool factory function
 * @param guardrail - Pre-tool hook from createDirectoryGuardrail()
 * @param getCwd - Function that returns the current working directory
 * @returns Wrapped tool factory
 */
export declare function wrapToolWithGuardrail<T extends (...args: unknown[]) => unknown>(factory: T, guardrail: ReturnType<typeof createDirectoryGuardrail>, getCwd: () => string): T;
/**
 * Error thrown when a guardrail vetoes a tool call.
 * Tools should catch this and return a structured error to the agent.
 */
export declare class GuardrailVetoError extends Error {
    constructor(message: string);
}
/**
 * Measure the overhead of a guardrail check in milliseconds.
 * Used by tests to verify the <5ms performance requirement.
 */
export declare function measureGuardrailOverhead(guardrail: ReturnType<typeof createDirectoryGuardrail>): number;
//# sourceMappingURL=guardrails.d.ts.map