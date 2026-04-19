/**
 * Guardrails module — Runtime-enforced constraints for Foreman pipeline agents.
 *
 * Provides pre-tool hooks that verify agent operating context before execution,
 * preventing common failure modes like wrong-worktree edits and cross-directory
 * command injection.
 *
 * @module src/orchestrator/guardrails
 */

import { join, isAbsolute, resolve, relative } from "node:path";

// ── Types ─────────────────────────────────────────────────────────────────

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

// ── Path utilities ───────────────────────────────────────────────────────

/**
 * Normalize a path for comparison.
 * Resolves `..`, `.`, and trailing slashes to ensure consistent comparison.
 */
function normalizePath(p: string): string {
  return resolve(p).replace(/\\/g, "/").replace(/\/$/, "");
}

/**
 * Returns true if `childPath` is the same as or a child of `parentPath`.
 */
function isSameOrChildPath(parentPath: string, childPath: string): boolean {
  const parent = normalizePath(parentPath);
  const child = normalizePath(childPath);
  return child === parent || child.startsWith(parent + "/");
}

/**
 * Attempt to correct an edit/write file path from a wrong worktree to the expected one.
 *
 * Algorithm:
 * 1. If the path is relative, resolve it against `actualCwd`.
 * 2. Check if it points to the wrong worktree (starts with `wrongWorktreePrefix`).
 * 3. Replace the wrong prefix with `correctWorktreePrefix`.
 *
 * @param filePath - The path from the tool call (may be absolute or relative).
 * @param actualCwd - The agent's actual current working directory.
 * @param expectedCwd - The expected worktree path.
 * @returns The corrected file path.
 */
function correctFilePath(
  filePath: string,
  actualCwd: string,
  expectedCwd: string,
): string {
  // Resolve relative paths against actual cwd
  const absolutePath = isAbsolute(filePath)
    ? resolve(filePath)
    : resolve(actualCwd, filePath);

  const actualNorm = normalizePath(actualCwd);
  const expectedNorm = normalizePath(expectedCwd);

  // If the path is under the actual cwd but not the expected cwd, it's wrong
  if (isSameOrChildPath(actualCwd, absolutePath) && !isSameOrChildPath(expectedCwd, absolutePath)) {
    // Compute the relative path from actualCwd
    const relPath = relative(actualNorm, absolutePath);
    // Re-base it under expectedCwd
    const corrected = join(expectedNorm, relPath).replace(/\\/g, "/");
    return corrected;
  }

  // If path starts with a different worktree prefix, try to correct
  // Check if it's a known worktree path pattern (e.g., .foreman-worktrees/<repo>/<seedId>/...)
  const wrongWorktreeMatch = /^.*?(\.foreman-worktrees\/[^\/]+\/[^\/]+)/.exec(absolutePath);
  if (wrongWorktreeMatch) {
    const wrongPrefix = wrongWorktreeMatch[1];
    if (wrongPrefix !== expectedNorm) {
      // Replace the wrong prefix with the correct one
      const suffix = absolutePath.slice(wrongPrefix.length);
      const corrected = (expectedNorm + suffix).replace(/\\/g, "/");
      return corrected;
    }
  }

  // Path is already correct or can't be corrected
  return filePath;
}

// ── Main guardrail function ───────────────────────────────────────────────

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
export function createDirectoryGuardrail(
  config: GuardrailConfig,
  logEvent: (eventType: string, details: Record<string, unknown>) => void,
  projectId: string,
  runId: string,
): (
  toolName: string,
  args: Record<string, unknown>,
  currentCwd: string,
) => GuardrailResult {
  const mode = config.directory?.mode ?? "auto-correct";
  const allowedPaths = config.directory?.allowedPaths;
  const expectedCwd = config.expectedCwd;

  return (toolName: string, args: Record<string, unknown>, currentCwd: string): GuardrailResult => {
    // Disabled mode: no checks
    if (mode === "disabled") {
      return { allowed: true };
    }

    const currentNorm = normalizePath(currentCwd);
    const expectedNorm = normalizePath(expectedCwd);

    // Check if cwd matches expected
    if (currentNorm === expectedNorm) {
      // Even in the correct cwd, check allowedPaths if configured
      if (allowedPaths && allowedPaths.length > 0) {
        const isAllowed = allowedPaths.some((prefix) => currentNorm.startsWith(normalizePath(prefix)));
        if (!isAllowed) {
          const details = {
            tool: toolName,
            expectedCwd,
            actualCwd: currentCwd,
            allowedPaths,
            vetoedAt: new Date().toISOString(),
          };
          logEvent("guardrail-veto", { ...details, projectId, runId });
          return {
            allowed: false,
            reason: `Working directory ${currentCwd} is not in allowed paths: ${allowedPaths.join(", ")}`,
            eventType: "guardrail-veto",
          };
        }
      }
      return { allowed: true };
    }

    // cwd is wrong
    if (mode === "veto") {
      const details = {
        tool: toolName,
        expectedCwd,
        actualCwd: currentCwd,
        vetoedAt: new Date().toISOString(),
      };
      logEvent("guardrail-veto", { ...details, projectId, runId });
      return {
        allowed: false,
        reason: `Working directory ${currentCwd} does not match expected worktree ${expectedCwd}`,
        eventType: "guardrail-veto",
      };
    }

    // auto-correct mode
    if (toolName === "Bash" || toolName === "bash") {
      const cmd = args["command"] as string | undefined;
      if (cmd) {
        const correctedArgs = { ...args, command: `cd "${expectedCwd}" && ${cmd}` };
        const details = {
          tool: toolName,
          expectedCwd,
          actualCwd: currentCwd,
          correction: "prepended cd to command",
          correctedAt: new Date().toISOString(),
        };
        logEvent("guardrail-corrected", { ...details, projectId, runId });
        return {
          allowed: true,
          correctedArgs,
          correctedCwd: expectedCwd,
          eventType: "guardrail-corrected",
        };
      }
    }

    // For Edit and Write tools, correct the file path
    if (toolName === "Edit" || toolName === "edit") {
      const path = args["path"] as string | undefined;
      if (path) {
        const corrected = correctFilePath(path, currentCwd, expectedCwd);
        if (corrected !== path) {
          const correctedArgs = { ...args, path: corrected };
          const details = {
            tool: toolName,
            expectedCwd,
            actualCwd: currentCwd,
            originalPath: path,
            correctedPath: corrected,
            correction: "corrected file path",
            correctedAt: new Date().toISOString(),
          };
          logEvent("guardrail-corrected", { ...details, projectId, runId });
          return {
            allowed: true,
            correctedArgs,
            correctedCwd: expectedCwd,
            eventType: "guardrail-corrected",
          };
        }
      }
    }

    if (toolName === "Write" || toolName === "write") {
      const path = args["path"] as string | undefined;
      if (path) {
        const corrected = correctFilePath(path, currentCwd, expectedCwd);
        if (corrected !== path) {
          const correctedArgs = { ...args, path: corrected };
          const details = {
            tool: toolName,
            expectedCwd,
            actualCwd: currentCwd,
            originalPath: path,
            correctedPath: corrected,
            correction: "corrected file path",
            correctedAt: new Date().toISOString(),
          };
          logEvent("guardrail-corrected", { ...details, projectId, runId });
          return {
            allowed: true,
            correctedArgs,
            correctedCwd: expectedCwd,
            eventType: "guardrail-corrected",
          };
        }
      }
    }

    // For other tools, just prepend cd to the command or return veto
    // Bash is the main concern; for other tools, use veto for safety
    return {
      allowed: false,
      reason: `Working directory ${currentCwd} does not match expected worktree ${expectedCwd} for tool ${toolName}`,
      eventType: "guardrail-veto",
    };
  };
}

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
export function wrapToolWithGuardrail<T extends (...args: unknown[]) => unknown>(
  factory: T,
  guardrail: ReturnType<typeof createDirectoryGuardrail>,
  getCwd: () => string,
): T {
  return ((...factoryArgs: Parameters<T>): ReturnType<T> => {
    // The tool factory receives (cwd, ...rest). Extract cwd and tool name.
    const [factoryCwd, ...restArgs] = factoryArgs;
    // The tool name is typically derived from the factory function name
    // We infer it from the args passed
    const toolName = extractToolName(factory);
    const currentCwd = getCwd();
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const toolArgs = (restArgs[0] as Record<string, unknown>) ?? {};

    const result = guardrail(toolName, toolArgs, currentCwd);

    if (!result.allowed) {
      throw new GuardrailVetoError(result.reason ?? `Guardrail vetoed ${toolName}`);
    }

    // If corrections were made, pass corrected args to the factory
    if (result.correctedArgs && restArgs.length > 0) {
      restArgs[0] = result.correctedArgs;
    }

    // Use the corrected cwd if provided
    const effectiveCwd = result.correctedCwd ?? (factoryCwd as string);

    return factory(effectiveCwd as Parameters<T>[0], ...restArgs) as ReturnType<T>;
  }) as T;
}

/**
 * Extract the tool name from a tool factory function.
 * Tool factories are named after their tool (e.g., createReadTool → "Read").
 */
function extractToolName(factory: (...args: unknown[]) => unknown): string {
  const name = factory.name;
  if (!name) return "Unknown";

  // Remove "create" prefix and "Tool" suffix
  let toolName = name.replace(/^create/, "").replace(/Tool$/, "");

  // Capitalize first letter
  if (toolName.length > 0) {
    toolName = toolName[0].toUpperCase() + toolName.slice(1);
  }

  // Handle special cases
  if (toolName === "Grep") return "Grep";
  if (toolName === "Find") return "Find";
  if (toolName === "Ls") return "LS";

  return toolName;
}

/**
 * Error thrown when a guardrail vetoes a tool call.
 * Tools should catch this and return a structured error to the agent.
 */
export class GuardrailVetoError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "GuardrailVetoError";
  }
}

// ── Performance measurement ─────────────────────────────────────────────

/**
 * Measure the overhead of a guardrail check in milliseconds.
 * Used by tests to verify the <5ms performance requirement.
 */
export function measureGuardrailOverhead(
  guardrail: ReturnType<typeof createDirectoryGuardrail>,
): number {
  const start = performance.now();
  guardrail("Edit", { path: "/some/file.ts" }, "/some/worktree");
  const end = performance.now();
  return end - start;
}