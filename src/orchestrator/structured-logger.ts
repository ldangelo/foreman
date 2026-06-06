/**
 * Structured Logger — Foreman pipeline logging with consistent issue context.
 *
 * Outputs JSON log entries with standardized fields for observability:
 *   - level: info | warn | error
 *   - timestamp: ISO 8601
 *   - message: human-readable message
 *   - issueId / issueIdentifier: seed/bead identifier
 *   - sessionId: SDK session identifier
 *   - runId: pipeline run UUID
 *   - attempt: retry attempt number
 *
 * @module src/orchestrator/structured-logger
 */

export interface StructuredLogContext {
  issueId?: string | null;
  issueIdentifier?: string | null;
  sessionId?: string | null;
  runId?: string | null;
  attempt?: number | null;
}

export type LogLevel = "info" | "warn" | "error";

export interface StructuredLogEntry {
  level: LogLevel;
  timestamp: string;
  message: string;
  issueId: string | null;
  issueIdentifier: string | null;
  sessionId: string | null;
  runId: string | null;
  attempt: number | null;
}

/**
 * Creates a structured log entry with consistent context fields.
 */
function createLogEntry(
  level: LogLevel,
  message: string,
  context: StructuredLogContext,
): StructuredLogEntry {
  return {
    level,
    timestamp: new Date().toISOString(),
    message,
    issueId: context.issueId ?? null,
    issueIdentifier: context.issueIdentifier ?? null,
    sessionId: context.sessionId ?? null,
    runId: context.runId ?? null,
    attempt: context.attempt ?? null,
  };
}

/**
 * StructuredLogger outputs JSON log entries with consistent context fields.
 *
 * Context is set at creation time and merged with each log call. This allows
 * a single logger instance to be reused across all operations within a
 * pipeline run while maintaining consistent issue/run identifiers.
 *
 * @example
 * ```typescript
 * const logger = new StructuredLogger({
 *   issueId: "ABC-123",
 *   runId: "run-456",
 *   sessionId: "thread-abc-turn-1",
 *   attempt: 1,
 * });
 * logger.info("Dispatching task");
 * logger.error("Task failed", { issueId: "XYZ-789" }); // override context
 * ```
 */
export class StructuredLogger {
  private context: StructuredLogContext;

  constructor(context: StructuredLogContext = {}) {
    // Auto-populate issueIdentifier from issueId if not explicitly set
    const resolvedContext = { ...context };
    if (resolvedContext.issueId !== undefined && resolvedContext.issueIdentifier === undefined) {
      resolvedContext.issueIdentifier = resolvedContext.issueId;
    }
    this.context = resolvedContext;
  }

  /**
   * Update the logger context (e.g., after session key is established).
   * Merges with existing context, allowing partial updates.
   */
  setContext(updates: Partial<StructuredLogContext>): void {
    this.context = { ...this.context, ...updates };
  }

  /**
   * Create a child logger with additional context merged into the parent context.
   */
  child(additionalContext: Partial<StructuredLogContext>): StructuredLogger {
    const child = new StructuredLogger({ ...this.context, ...additionalContext });
    return child;
  }

  private write(level: LogLevel, message: string, contextOverrides?: Partial<StructuredLogContext>): void {
    const entry = createLogEntry(level, message, { ...this.context, ...contextOverrides });
    const json = JSON.stringify(entry);

    if (level === "error") {
      console.error(json);
    } else if (level === "warn") {
      console.warn(json);
    } else {
      console.log(json);
    }
  }

  /**
   * Log an info-level message.
   */
  info(message: string, contextOverrides?: Partial<StructuredLogContext>): void {
    this.write("info", message, contextOverrides);
  }

  /**
   * Log a warning-level message.
   */
  warn(message: string, contextOverrides?: Partial<StructuredLogContext>): void {
    this.write("warn", message, contextOverrides);
  }

  /**
   * Log an error-level message.
   */
  error(message: string, contextOverrides?: Partial<StructuredLogContext>): void {
    this.write("error", message, contextOverrides);
  }
}

/**
 * Extract the SDK session ID from a foreman session key.
 *
 * Format: foreman:sdk:<model>:<runId>[:pid-<pid>]:session-<sessionId>
 *
 * @param sessionKey - The full session key string, or null
 * @returns The session ID portion, or null if not found
 */
export function extractSessionId(sessionKey: string | null): string | null {
  if (!sessionKey) return null;
  const m = sessionKey.match(/session-(.+)$/);
  return m ? m[1] : null;
}

/**
 * Create a structured logger with context from environment variables and explicit values.
 *
 * Reads FOREMAN_RUN_ID, FOREMAN_SEED_ID, FOREMAN_PHASE from process.env.
 * These are set by the dispatcher when spawning agent workers.
 */
export function createStructuredLogger(
  explicitContext: StructuredLogContext = {},
): StructuredLogger {
  const context: StructuredLogContext = {
    runId: process.env["FOREMAN_RUN_ID"] ?? explicitContext.runId,
    issueId: process.env["FOREMAN_SEED_ID"] ?? explicitContext.issueId,
    issueIdentifier: process.env["FOREMAN_SEED_ID"] ?? explicitContext.issueIdentifier,
    ...explicitContext,
  };

  return new StructuredLogger(context);
}