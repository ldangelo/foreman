/**
 * pi-sdk-runner.ts — Run Pi agent sessions via the SDK (in-process).
 *
 * Replaces pi-runner.ts which spawned `pi --mode rpc` as a child process
 * and parsed JSONL events from stdout.  The SDK approach eliminates:
 *   - Child process spawning + JSONL parsing
 *   - Pi binary resolution (`which pi`, Homebrew fallback)
 *   - Env-var-based config passing (FOREMAN_ALLOWED_TOOLS, etc.)
 *   - EPIPE crashes on parent exit
 *
 * Each phase call creates a fresh AgentSession (in-memory, no persistence),
 * sends the prompt, awaits completion, and returns structured results.
 */

import {
  createAgentSession,
  SessionManager,
  SettingsManager,
  AuthStorage,
  getAgentDir,
  createReadTool,
  createBashTool,
  createEditTool,
  createWriteTool,
  createGrepTool,
  createFindTool,
  createLsTool,
  type AgentSessionEvent,
  type ToolDefinition,
} from "@mariozechner/pi-coding-agent";
import { getModel } from "@mariozechner/pi-ai";
import { appendFile } from "node:fs/promises";
import { join } from "node:path";

const OUTER_RETRYABLE_ERROR_PATTERNS = [
  /connection error\.?$/i,
  /fetch failed/i,
  /socket hang up/i,
  /timed?\s*out/i,
  /econnreset/i,
  /econnrefused/i,
  /enotfound/i,
  /temporary(?:ily)? unavailable/i,
  /network error/i,
] as const;
const MAX_FRESH_SESSION_ATTEMPTS = 2;

// ── Public interface (compatible with pi-runner.ts) ─────────────────────

export interface PiRunResult {
  success: boolean;
  costUsd: number;
  turns: number;
  toolCalls: number;
  toolBreakdown: Record<string, number>;
  tokensIn: number;
  tokensOut: number;
  errorMessage?: string;
  /** Captured assistant text output (concatenated from all text deltas). */
  outputText?: string;
}

export interface PiRunOptions {
  prompt: string;
  systemPrompt: string;
  cwd: string;
  /** Model string like "anthropic/claude-sonnet-4-6" */
  model: string;
  /** Allowed tool names for this phase (e.g. ["Read", "Bash", "Edit", "Write"]) */
  allowedTools?: readonly string[];
  /** Custom ToolDefinitions to register (e.g. send-mail tool) */
  customTools?: ToolDefinition[];
  logFile?: string;
  onToolCall?: (name: string, input: Record<string, unknown>) => void;
  onTurnEnd?: (turn: number) => void;
  /** Called with text deltas as the assistant streams output. */
  onText?: (text: string) => void;
}

// ── Tool name → factory mapping ─────────────────────────────────────────

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type ToolFactory = (cwd: string, ...args: any[]) => any;

const TOOL_FACTORIES: Record<string, ToolFactory> = {
  Read: createReadTool,
  Bash: createBashTool,
  Edit: createEditTool,
  Write: createWriteTool,
  Grep: createGrepTool,
  Find: createFindTool,
  LS: createLsTool,
};

/**
 * Build the tool array from allowed tool names.
 * Unknown names are silently skipped (they may be custom tools registered separately).
 */
function buildTools(allowedNames: readonly string[], cwd: string) {
  const tools = [];
  for (const name of allowedNames) {
    const factory = TOOL_FACTORIES[name];
    if (factory) tools.push(factory(cwd));
  }
  return tools;
}

function isRetryableFreshSessionError(message: string | undefined): boolean {
  if (!message) return false;
  return OUTER_RETRYABLE_ERROR_PATTERNS.some((pattern) => pattern.test(message));
}

function shouldRetryWithFreshSession(result: PiRunResult): boolean {
  return (
    !result.success
    && result.toolCalls === 0
    && result.tokensOut === 0
    && isRetryableFreshSessionError(result.errorMessage)
  );
}

function serializeErrorDetails(err: unknown): string | undefined {
  if (!(err instanceof Error)) return undefined;
  const details: Record<string, unknown> = {};
  const extended = err as Error & {
    code?: unknown;
    status?: unknown;
    type?: unknown;
    cause?: unknown;
  };
  if (extended.code !== undefined) details.code = extended.code;
  if (extended.status !== undefined) details.status = extended.status;
  if (extended.type !== undefined) details.type = extended.type;
  if (extended.cause instanceof Error) {
    details.cause = {
      name: extended.cause.name,
      message: extended.cause.message,
      ...(
        (extended.cause as Error & { code?: unknown }).code !== undefined
          ? { code: (extended.cause as Error & { code?: unknown }).code }
          : {}
      ),
    };
  }
  return Object.keys(details).length > 0 ? JSON.stringify(details) : undefined;
}

// ── Model resolution ────────────────────────────────────────────────────

/**
 * Parse a model string like "anthropic/claude-sonnet-4-6" into provider+modelId.
 * Supports any provider (anthropic, openai, google, etc.) — the Pi SDK's
 * getModel() handles provider-specific API resolution.
 */
function parseModelString(model: string) {
  const slash = model.indexOf("/");
  if (slash === -1) return { provider: "anthropic", modelId: model };
  return {
    provider: model.slice(0, slash),
    modelId: model.slice(slash + 1),
  };
}

// ── Main entry point ────────────────────────────────────────────────────

/**
 * Run a single Pi SDK session (awaits completion before resolving).
 *
 * Creates an in-memory AgentSession, sends the prompt, listens for events
 * to track tool calls / turns / cost, and resolves with structured results.
 */
async function runSinglePiSdkSession(
  opts: PiRunOptions,
  writeLog: (line: string) => void,
): Promise<PiRunResult> {
  // Resolve model — getModel is strictly typed for known providers/IDs;
  // use type assertions for dynamic values from workflow YAML.
  const { provider, modelId } = parseModelString(opts.model);
  const model = getModel(provider as never, modelId as never);

  // Build tool set from allowed names
  const tools = opts.allowedTools
    ? buildTools(opts.allowedTools, opts.cwd)
    : buildTools(["Read", "Bash", "Edit", "Write", "Grep", "Find", "LS"], opts.cwd);

  // Accumulators
  let totalTurns = 0;
  let totalToolCalls = 0;
  const toolBreakdown: Record<string, number> = {};
  let success = true;
  let errorMessage: string | undefined;
  const textChunks: string[] = [];

  try {
    // Explicitly set agentDir and auth so detached worker processes find credentials.
    const agentDir = getAgentDir();
    const authStorage = AuthStorage.create(join(agentDir, "auth.json"));

    const { session } = await createAgentSession({
      cwd: opts.cwd,
      agentDir,
      authStorage,
      model,
      thinkingLevel: "medium",
      tools,
      customTools: opts.customTools,
      sessionManager: SessionManager.inMemory(),
      settingsManager: SettingsManager.inMemory(),
    });

    // Subscribe to events for tracking
    session.subscribe((event: AgentSessionEvent) => {
      switch (event.type) {
        case "turn_start":
          totalTurns++;
          break;

        case "turn_end":
          opts.onTurnEnd?.(totalTurns);
          break;

        case "message_update": {
          // Capture assistant text deltas
          const updateEvent = event as Record<string, unknown>;
          const assistantEvent = updateEvent.assistantMessageEvent as Record<string, unknown> | undefined;
          if (assistantEvent?.type === "text_delta") {
            const delta = assistantEvent.delta as string | undefined;
            if (delta) {
              textChunks.push(delta);
              opts.onText?.(delta);
            }
          }
          break;
        }

        case "tool_execution_start": {
          const toolName = (event as Record<string, unknown>).toolName as string | undefined;
          if (toolName) {
            totalToolCalls++;
            toolBreakdown[toolName] = (toolBreakdown[toolName] ?? 0) + 1;
            const input = (event as Record<string, unknown>).args as Record<string, unknown> | undefined;
            opts.onToolCall?.(toolName, input ?? {});
          }
          break;
        }

        case "agent_end": {
          const endEvent = event as Record<string, unknown>;
          if (endEvent.success === false) {
            success = false;
            errorMessage = (endEvent.message as string) ?? "Agent ended without success";
          }
          break;
        }

        case "auto_retry_end": {
          // Pi SDK retried and still failed (e.g. persistent rate limit).
          // Surface the error so callers get a meaningful failure message.
          const retryEvent = event as Record<string, unknown>;
          if (retryEvent.success === false) {
            success = false;
            errorMessage = (retryEvent.finalError as string) ?? "All retries exhausted";
          }
          break;
        }
      }

      writeLog(JSON.stringify(event));
    });

    // Send the prompt and await completion.
    // Prepend systemPrompt as role context since the Pi SDK manages its own
    // system prompt (from CLAUDE.md, extensions, etc.) and doesn't accept one directly.
    const fullPrompt = opts.systemPrompt
      ? `${opts.systemPrompt}\n\n${opts.prompt}`
      : opts.prompt;
    await session.prompt(fullPrompt);

    // Extract cost and token usage from session stats
    const stats = session.getSessionStats();
    const costUsd = stats.cost ?? 0;
    const tokensIn = stats.tokens?.input ?? 0;
    const tokensOut = stats.tokens?.output ?? 0;

    // Clean up
    session.dispose();

    writeLog(
      `[pi-sdk-runner] success=${success} turns=${totalTurns} tools=${totalToolCalls} cost=$${costUsd.toFixed(4)} tokensIn=${tokensIn} tokensOut=${tokensOut}`,
    );

    return {
      success,
      costUsd,
      turns: totalTurns,
      toolCalls: totalToolCalls,
      toolBreakdown,
      tokensIn,
      tokensOut,
      errorMessage: success ? undefined : errorMessage,
      outputText: textChunks.length > 0 ? textChunks.join("") : undefined,
    };
  } catch (err: unknown) {
    const reason = err instanceof Error ? err.message : String(err);
    const detail = serializeErrorDetails(err);
    writeLog(`[pi-sdk-runner] ERROR: ${reason}`);
    if (detail) writeLog(`[pi-sdk-runner] ERROR_DETAIL: ${detail}`);
    return {
      success: false,
      costUsd: 0,
      turns: totalTurns,
      toolCalls: totalToolCalls,
      toolBreakdown,
      tokensIn: 0,
      tokensOut: 0,
      errorMessage: reason,
    };
  }
}

export async function runWithPiSdk(opts: PiRunOptions): Promise<PiRunResult> {
  const writeLog = (line: string): void => {
    if (!opts.logFile) return;
    appendFile(opts.logFile, line + "\n").catch(() => { /* non-fatal */ });
  };

  let result = await runSinglePiSdkSession(opts, writeLog);
  for (let attempt = 2; attempt <= MAX_FRESH_SESSION_ATTEMPTS && shouldRetryWithFreshSession(result); attempt++) {
    writeLog(
      `[pi-sdk-runner] retrying with fresh session attempt=${attempt}/${MAX_FRESH_SESSION_ATTEMPTS} reason=${result.errorMessage ?? "unknown"}`,
    );
    result = await runSinglePiSdkSession(opts, writeLog);
  }
  return result;
}
