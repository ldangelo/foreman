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

// ── Public interface (compatible with pi-runner.ts) ─────────────────────

export interface PiRunResult {
  success: boolean;
  costUsd: number;
  turns: number;
  toolCalls: number;
  toolBreakdown: Record<string, number>;
  errorMessage?: string;
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

// ── Model resolution ────────────────────────────────────────────────────

/**
 * Parse a model string like "anthropic/claude-sonnet-4-6" into provider+modelId.
 */
function parseModelString(model: string) {
  const slash = model.indexOf("/");
  if (slash === -1) return { provider: "anthropic" as const, modelId: model };
  return {
    provider: model.slice(0, slash) as "anthropic",
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
export async function runWithPiSdk(opts: PiRunOptions): Promise<PiRunResult> {
  // Resolve model
  const { provider, modelId } = parseModelString(opts.model);
  // getModel is strictly typed for known model IDs; use type assertion for dynamic IDs
  const model = getModel(provider, modelId as never);

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

  const writeLog = (line: string): void => {
    if (!opts.logFile) return;
    appendFile(opts.logFile, line + "\n").catch(() => { /* non-fatal */ });
  };

  try {
    const { session } = await createAgentSession({
      cwd: opts.cwd,
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
      }

      writeLog(JSON.stringify(event));
    });

    // Send the prompt and await completion
    await session.prompt(opts.prompt);

    // Extract cost from session stats
    const stats = session.getSessionStats();
    const costUsd = stats.cost ?? 0;

    // Clean up
    session.dispose();

    writeLog(
      `[pi-sdk-runner] success=${success} turns=${totalTurns} tools=${totalToolCalls} cost=$${costUsd.toFixed(4)}`,
    );

    return {
      success,
      costUsd,
      turns: totalTurns,
      toolCalls: totalToolCalls,
      toolBreakdown,
      errorMessage: success ? undefined : errorMessage,
    };
  } catch (err: unknown) {
    const reason = err instanceof Error ? err.message : String(err);
    writeLog(`[pi-sdk-runner] ERROR: ${reason}`);
    return {
      success: false,
      costUsd: 0,
      turns: totalTurns,
      toolCalls: totalToolCalls,
      toolBreakdown,
      errorMessage: reason,
    };
  }
}
