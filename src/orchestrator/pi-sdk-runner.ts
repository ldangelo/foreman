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
  DefaultResourceLoader,
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
import { createDirectoryGuardrail, wrapToolWithGuardrail, type GuardrailConfig } from "./guardrails.js";
import { getModel } from "@mariozechner/pi-ai";
import { appendFile } from "node:fs/promises";
import { join } from "node:path";
import {
  createPhaseTrace,
  createPiObservabilityExtensionWithEmitter,
  finalizePhaseTrace,
} from "./pi-observability-extension.js";
import type { PhaseTraceLiveEvent, PhaseTraceMetadata } from "./pi-observability-types.js";
import { writePhaseTrace } from "./pi-observability-writer.js";

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
  /** Relative path to the JSON phase trace, when observability is enabled. */
  traceFile?: string;
  /** Relative path to the markdown phase trace, when observability is enabled. */
  traceMarkdownFile?: string;
  /** Observability warnings emitted for this phase. */
  traceWarnings?: string[];
  /** Heuristic for whether a command workflow appears to have been honored. */
  commandHonored?: boolean;
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
  /** Directory guardrail config. When set, wraps tool factories with cwd verification (FR-1). */
  guardrailConfig?: GuardrailConfig;
  /** Optional phase-level observability metadata used to emit Pi hook traces. */
  observability?: PhaseTraceMetadata;
  /** Live observability callback fired from Pi extension hooks. */
  onTraceEvent?: (event: PhaseTraceLiveEvent) => void;
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
function buildTools(
  allowedNames: readonly string[],
  cwd: string,
  guardrailConfig?: GuardrailConfig,
) {
  const tools = [];

  // If guardrail config is provided, create a pre-tool hook and wrap factories
  const guardrailHook = guardrailConfig
    ? createDirectoryGuardrail(
        guardrailConfig,
        // Use a no-op logger in pi-sdk-runner since store.logEvent isn't available here.
        // The guardrail-corrected/veto events are still emitted via the hook's return value.
        (_eventType: string, _details: Record<string, unknown>) => { /* no-op in pi-sdk context */ },
        "pi-sdk-runner",
        "",
      )
    : null;

  for (const name of allowedNames) {
    const factory = TOOL_FACTORIES[name];
    if (!factory) continue;

    if (guardrailHook) {
      // Wrap the factory with guardrail — intercepts tool calls before execution
      const wrappedFactory = wrapToolWithGuardrail(
        factory as (...args: unknown[]) => unknown,
        guardrailHook,
        () => process.cwd(),
      );
      tools.push(wrappedFactory(cwd));
    } else {
      tools.push(factory(cwd));
    }
  }
  return tools;
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
export async function runWithPiSdk(opts: PiRunOptions): Promise<PiRunResult> {
  // Resolve model — getModel is strictly typed for known providers/IDs;
  // use type assertions for dynamic values from workflow YAML.
  const { provider, modelId } = parseModelString(opts.model);
  const model = getModel(provider as never, modelId as never);

  // Build tool set from allowed names
  const tools = opts.allowedTools
    ? buildTools(opts.allowedTools, opts.cwd, opts.guardrailConfig)
    : buildTools(["Read", "Bash", "Edit", "Write", "Grep", "Find", "LS"], opts.cwd, opts.guardrailConfig);

  // Accumulators
  let totalTurns = 0;
  let totalToolCalls = 0;
  const toolBreakdown: Record<string, number> = {};
  let success = true;
  let errorMessage: string | undefined;
  const textChunks: string[] = [];
  const phaseTrace = opts.observability ? createPhaseTrace(opts.observability) : undefined;

  const writeLog = (line: string): void => {
    if (!opts.logFile) return;
    appendFile(opts.logFile, line + "\n").catch(() => { /* non-fatal */ });
  };

  try {
    // Explicitly set agentDir and auth so detached worker processes find credentials.
    const agentDir = getAgentDir();
    const authStorage = AuthStorage.create(join(agentDir, "auth.json"));
    const resourceLoader = new DefaultResourceLoader({
      cwd: opts.cwd,
      agentDir,
      settingsManager: SettingsManager.create(opts.cwd, agentDir),
      extensionFactories: phaseTrace ? [createPiObservabilityExtensionWithEmitter(phaseTrace, opts.onTraceEvent)] : [],
    });
    await resourceLoader.reload();

    const { session } = await createAgentSession({
      cwd: opts.cwd,
      agentDir,
      authStorage,
      model,
      thinkingLevel: "medium",
      tools,
      customTools: opts.customTools,
      resourceLoader,
      sessionManager: SessionManager.inMemory(),
      settingsManager: SettingsManager.create(opts.cwd, agentDir),
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

    let tracePaths;
    if (phaseTrace) {
      finalizePhaseTrace(phaseTrace, {
        success,
        error: success ? undefined : errorMessage,
        finalMessage: textChunks.length > 0 ? textChunks.join("") : undefined,
      });
      tracePaths = await writePhaseTrace(phaseTrace);
      opts.onTraceEvent?.({
        kind: "complete",
        phase: phaseTrace.phase,
        seedId: phaseTrace.seedId,
        message: `phase=${phaseTrace.phase} success=${String(success)} artifactPresent=${String(phaseTrace.artifactPresent)} commandHonored=${String(phaseTrace.commandHonored)}`,
        traceFile: tracePaths.relativeJsonPath,
        traceMarkdownFile: tracePaths.relativeMarkdownPath,
        commandHonored: phaseTrace.commandHonored,
      });
    }

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
      traceFile: tracePaths?.relativeJsonPath,
      traceMarkdownFile: tracePaths?.relativeMarkdownPath,
      traceWarnings: phaseTrace?.warnings,
      commandHonored: phaseTrace?.commandHonored,
    };
  } catch (err: unknown) {
    const reason = err instanceof Error ? err.message : String(err);
    writeLog(`[pi-sdk-runner] ERROR: ${reason}`);
    let tracePaths;
    if (phaseTrace) {
      finalizePhaseTrace(phaseTrace, {
        success: false,
        error: reason,
        finalMessage: textChunks.length > 0 ? textChunks.join("") : undefined,
      });
      tracePaths = await writePhaseTrace(phaseTrace);
      opts.onTraceEvent?.({
        kind: "complete",
        phase: phaseTrace.phase,
        seedId: phaseTrace.seedId,
        message: `phase=${phaseTrace.phase} success=false error=${reason}`,
        traceFile: tracePaths.relativeJsonPath,
        traceMarkdownFile: tracePaths.relativeMarkdownPath,
        commandHonored: phaseTrace.commandHonored,
      });
    }
    return {
      success: false,
      costUsd: 0,
      turns: totalTurns,
      toolCalls: totalToolCalls,
      toolBreakdown,
      tokensIn: 0,
      tokensOut: 0,
      errorMessage: reason,
      traceFile: tracePaths?.relativeJsonPath,
      traceMarkdownFile: tracePaths?.relativeMarkdownPath,
      traceWarnings: phaseTrace?.warnings,
      commandHonored: phaseTrace?.commandHonored,
    };
  }
}
