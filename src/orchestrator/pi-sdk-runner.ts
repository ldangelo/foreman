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
  type ExtensionAPI,
  type ExtensionFactory,
  type ToolDefinition,
} from "@mariozechner/pi-coding-agent";
import { createDirectoryGuardrail, wrapToolWithGuardrail, type GuardrailConfig } from "./guardrails.js";
import { getModel } from "@mariozechner/pi-ai";
import { existsSync } from "node:fs";
import { appendFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  createPhaseTrace,
  createPiObservabilityExtensionWithEmitter,
  finalizePhaseTrace,
} from "./pi-observability-extension.js";
import type { PhaseTraceLiveEvent, PhaseTraceMetadata } from "./pi-observability-types.js";
import { writePhaseTrace } from "./pi-observability-writer.js";
import { REQUIRED_SKILLS } from "../lib/prompt-loader.js";
import { z } from "zod";
import type { ControlOutcome } from "./pi-sdk-tools.js";

// ── Public interface (compatible with pi-runner.ts) ─────────────────────

/**
 * Options for extracting structured JSON output from agent text.
 * When provided, the runner will look for content inside <tag>...</tag> markers,
 * parse it as JSON, and validate it against the Zod schema.
 */
export interface StructuredOutputOptions {
  /** Tag name to extract (e.g. "result" for <result>...</result>). */
  tag: string;
  /** Zod schema to validate the extracted JSON content. */
  schema: z.ZodType;
}

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
  /** Structured output extracted from outputText, validated against schema. Present when output option is specified. */
  output?: unknown;
  /** Error message if structured output extraction or validation failed. Does not indicate phase failure. */
  outputError?: string;
  /** Relative path to the JSON phase trace, when observability is enabled. */
  traceFile?: string;
  /** Relative path to the markdown phase trace, when observability is enabled. */
  traceMarkdownFile?: string;
  /** Observability warnings emitted for this phase. */
  traceWarnings?: string[];
  /** Heuristic for whether a command workflow appears to have been honored. */
  commandHonored?: boolean;
  /** Relative or repo-root paths written during the phase when a custom runner can provide them. */
  filesChanged?: string[];
  /** Control outcome from phase control tools (ask_operator, abort_phase, needs_retry). */
  controlOutcome?: ControlOutcome;
}

/**
 * Normalized stream event types for the onStreamEvent callback.
 * These provide a simplified, stable API surface over raw Pi SDK events.
 */
export type StreamEvent =
  | { type: "text"; iteration: number; timestamp: string; delta: string }
  | { type: "toolCall"; iteration: number; timestamp: string; toolCallId?: string; toolName: string; args: Record<string, unknown> }
  | { type: "toolCallFinished"; iteration: number; timestamp: string; toolCallId?: string; toolName: string; args?: Record<string, unknown>; result?: unknown; isError?: boolean }
  | { type: "turnStart"; iteration: number; timestamp: string }
  | { type: "turnEnd"; iteration: number; timestamp: string; tokensIn?: number; tokensOut?: number }
  | { type: "agentEnd"; iteration: number; timestamp: string; success: boolean; message?: string };

export interface ToolPolicyDecision {
  allowed: boolean;
  action: string;
  reason: string;
  message?: string | null;
}

export interface ToolPolicyContext {
  runId: string;
  taskId?: string;
  phaseId: string;
  workerId?: string;
}

export interface PiRunOptions {
  prompt: string;
  systemPrompt: string;
  cwd: string;
  /** Model string like "anthropic/claude-sonnet-4-6" */
  model: string;
  /** Maximum assistant turns before Foreman aborts the phase. */
  maxTurns?: number;
  /** Allowed tool names for this phase (e.g. ["Read", "Bash", "Edit", "Write"]) */
  allowedTools?: readonly string[];
  /** Custom ToolDefinitions to register (e.g. send-mail tool) */
  customTools?: ToolDefinition[];
  logFile?: string;
  onToolCall?: (name: string, input: Record<string, unknown>) => void;
  onTurnEnd?: (turn: number) => void;
  /** Called with text deltas as the assistant streams output. */
  onText?: (text: string) => void;
  /** Live stream of normalized events for observability integrations. */
  onStreamEvent?: (event: StreamEvent) => void;
  /** Directory guardrail config. When set, wraps tool factories with cwd verification (FR-1). */
  guardrailConfig?: GuardrailConfig;
  /** Optional phase-level observability metadata used to emit Pi hook traces. */
  observability?: PhaseTraceMetadata;
  /** Backend-owned policy gate called before each tool executes. */
  toolPolicy?: {
    context: ToolPolicyContext;
    check: (toolCallId: string, toolName: string, args: Record<string, unknown>) => Promise<ToolPolicyDecision>;
  };
  /** Live observability callback fired from Pi extension hooks. */
  onTraceEvent?: (event: PhaseTraceLiveEvent) => void;
  /** Optional structured output extraction. When provided, the runner will extract and validate JSON from outputText. */
  output?: StructuredOutputOptions;
}

// ── Tool name → factory mapping ─────────────────────────────────────────

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type ToolFactory = (cwd: string, ...args: any[]) => any;

export function isDangerousBashCommand(command: string): boolean {
  const normalized = command.toLowerCase().replace(/\s+/g, " ");
  return /\b(kill|pkill|killall)\b/.test(normalized)
    || /\bxargs\s+kill\b/.test(normalized)
    || /\bfuser\b.*\s-k\b/.test(normalized)
    || /\blsof\s+[^;&|]*-ti:?4766\b/.test(normalized)
    || /\bforeman\s+server\s+(stop|restart)\b/.test(normalized);
}

function createGuardedBashTool(cwd: string) {
  return createBashTool(cwd, {
    spawnHook: ({ command, cwd: hookCwd, env }) => {
      if (isDangerousBashCommand(command)) {
        const message = "Foreman worker safety guard blocked a destructive process-control command. Do not kill Foreman server or unrelated processes; use task-local validation commands and ask the operator for server restarts.";
        return {
          command: `printf '%s\\n' ${JSON.stringify(message)} >&2; exit 126`,
          cwd: hookCwd,
          env,
        };
      }

      return {
        command,
        cwd: hookCwd,
        env: {
          ...env,
          FOREMAN_SERVER_HTTP_ENABLED: "false",
          FOREMAN_SERVER_HTTP_PORT: "0",
        },
      };
    },
  });
}

const TOOL_FACTORIES: Record<string, ToolFactory> = {
  Read: createReadTool,
  Bash: createGuardedBashTool,
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
function wrapToolWithPolicy<T extends { name: string; execute: (...args: any[]) => Promise<unknown> }>(tool: T, policy: NonNullable<PiRunOptions["toolPolicy"]>): T {
  const originalExecute = tool.execute.bind(tool);
  return {
    ...tool,
    async execute(toolCallId: string, params: Record<string, unknown>, ...rest: unknown[]) {
      const decision = await policy.check(toolCallId, tool.name, params ?? {});
      if (!decision.allowed) {
        const message = `Foreman overwatch denied ${tool.name}: ${decision.reason}`;
        return {
          content: [{ type: "text" as const, text: message }],
          details: { deniedByOverwatch: true, reason: decision.reason, action: decision.action },
          isError: true,
        };
      }
      return originalExecute(toolCallId, params ?? {}, ...rest);
    },
  } as T;
}

function applyToolPolicy<T extends { name: string; execute: (...args: any[]) => Promise<unknown> }>(tools: T[], policy?: PiRunOptions["toolPolicy"]): T[] {
  if (!policy) return tools;
  return tools.map((tool) => wrapToolWithPolicy(tool, policy));
}

function buildTools(
  allowedNames: readonly string[],
  cwd: string,
  guardrailConfig?: GuardrailConfig,
  toolPolicy?: PiRunOptions["toolPolicy"],
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
  return applyToolPolicy(tools, toolPolicy);
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

export function shouldSandboxPiExtensions(env: NodeJS.ProcessEnv = process.env): boolean {
  return env.FOREMAN_PI_EXTENSIONS?.trim().toLowerCase() !== "user";
}

export interface SandboxedPiResourcePaths {
  extensionPaths: string[];
  skillPaths: string[];
  promptTemplatePaths: string[];
}

function firstExistingPath(paths: string[]): string | undefined {
  return paths.find((path) => existsSync(path));
}

function getForemanRoot(): string {
  return join(dirname(fileURLToPath(import.meta.url)), "..", "..");
}

function resolveEnsemblePiRoot(env: NodeJS.ProcessEnv = process.env): string | undefined {
  const foremanRoot = getForemanRoot();
  return firstExistingPath([
    env.FOREMAN_ENSEMBLE_PI_PATH?.trim() ?? "",
    env.ENSEMBLE_PI_PATH?.trim() ?? "",
    join(foremanRoot, "..", "ensemble", "packages", "pi"),
  ].filter(Boolean));
}

function resolveForemanSkillPath(skillName: string): string | undefined {
  const foremanRoot = getForemanRoot();
  return firstExistingPath([
    join(foremanRoot, "src", "defaults", "skills", skillName, "SKILL.md"),
    join(foremanRoot, "dist", "defaults", "skills", skillName, "SKILL.md"),
  ]);
}

function isDefined<T>(value: T | undefined): value is T {
  return value !== undefined;
}

function resolveForemanSkillPaths(): string[] {
  return REQUIRED_SKILLS.map((skillName) => resolveForemanSkillPath(skillName)).filter(isDefined);
}

export function getSandboxedPiResourcePaths(env: NodeJS.ProcessEnv = process.env): SandboxedPiResourcePaths {
  const extensionPaths: string[] = [];
  const skillPaths: string[] = [];
  const promptTemplatePaths: string[] = [];
  const ensemblePiRoot = resolveEnsemblePiRoot(env);

  if (ensemblePiRoot) {
    extensionPaths.push(join(ensemblePiRoot, "extensions"));
    skillPaths.push(join(ensemblePiRoot, "skills"));
    promptTemplatePaths.push(join(ensemblePiRoot, "prompts"));
  }

  skillPaths.push(...resolveForemanSkillPaths());

  return { extensionPaths, skillPaths, promptTemplatePaths };
}

export function normalizeLegacySlashPrompt(prompt: string): string {
  return prompt.replace(/^\/ensemble:([a-z0-9_-]+)(?=\s|$)/i, (_match, command: string) => (
    `/ensemble-${command.replace(/_/g, "-")}`
  ));
}

function createSystemPromptExtension(systemPrompt: string | undefined): ExtensionFactory | undefined {
  const trimmed = systemPrompt?.trim();
  if (!trimmed) return undefined;

  return (pi: ExtensionAPI) => {
    pi.on("before_agent_start", async (event) => ({
      systemPrompt: `${event.systemPrompt}\n\n${trimmed}`,
    }));
  };
}

function createLegacySlashPromptAliasExtension(): ExtensionFactory {
  return (pi: ExtensionAPI) => {
    pi.on("input", async (event: { text: string }) => {
      const normalized = normalizeLegacySlashPrompt(event.text);
      if (normalized === event.text) return { action: "continue" };
      return { action: "transform", text: normalized };
    });
  };
}

// ── Main entry point ────────────────────────────────────────────────────

/**
 * Run a single Pi SDK session (awaits completion before resolving).
 *
 * Creates an in-memory AgentSession, sends the prompt, listens for events
 * to track tool calls / turns / cost, and resolves with structured results.
 */
export function getPiSdkEventError(event: AgentSessionEvent): string | undefined {
  const eventRecord = event as Record<string, unknown>;
  if (eventRecord.stopReason === "error") {
    return typeof eventRecord.errorMessage === "string" && eventRecord.errorMessage
      ? eventRecord.errorMessage
      : "Pi SDK event stopped with error";
  }
  if (typeof eventRecord.errorMessage === "string" && eventRecord.errorMessage) {
    return eventRecord.errorMessage;
  }
  return undefined;
}

/**
 * Extract and validate structured output from agent text.
 * Looks for content between <tag>...</tag> markers, parses as JSON,
 * and validates against the provided Zod schema.
 *
 * Returns an object with either `output` (validated data) or `error` (failure message).
 * Does not throw — all errors are captured in the return value.
 */
export function extractStructuredOutput(
  outputText: string | undefined,
  options: StructuredOutputOptions,
): { output?: unknown; error?: string } {
  if (!outputText) {
    return { error: `No output text to extract from` };
  }

  // Build regex to find content between <tag>...</tag>
  // The DOTALL flag (s) makes . match newlines
  // tagEscaped is already properly escaped, use it directly without re-escaping
  const tagEscaped = options.tag.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const openTag = `<${tagEscaped}>`;
  const closeTag = `</${tagEscaped}>`;
  const regex = new RegExp(
    `${openTag}([\\s\\S]*?)${closeTag}`,
    "i",
  );

  const match = outputText.match(regex);
  if (!match) {
    return { error: `Tag <${options.tag}> not found in output` };
  }

  const jsonContent = match[1].trim();
  if (!jsonContent) {
    return { error: `Empty content inside <${options.tag}> tag` };
  }

  // Parse JSON
  let parsed: unknown;
  try {
    parsed = JSON.parse(jsonContent);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return { error: `Invalid JSON inside <${options.tag}>: ${message}` };
  }

  // Validate against schema
  try {
    const validated = options.schema.parse(parsed);
    return { output: validated };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return { error: `Schema validation failed for <${options.tag}>: ${message}` };
  }
}

export async function runWithPiSdk(opts: PiRunOptions): Promise<PiRunResult> {
  // Resolve model — getModel is strictly typed for known providers/IDs;
  // use type assertions for dynamic values from workflow YAML.
  const { provider, modelId } = parseModelString(opts.model);
  const model = getModel(provider as never, modelId as never);

  // Build tool set from allowed names
  const builtInTools = opts.allowedTools
    ? buildTools(opts.allowedTools, opts.cwd, opts.guardrailConfig, opts.toolPolicy)
    : buildTools(["Read", "Bash", "Edit", "Write", "Grep", "Find", "LS"], opts.cwd, opts.guardrailConfig, opts.toolPolicy);
  // Register built-ins as custom tool definitions so the policy-wrapped execute()
  // path is authoritative for every tool, including Read/Bash/Edit/Write.
  const tools = [] as never[];
  const customTools = [...builtInTools, ...applyToolPolicy(opts.customTools ?? [], opts.toolPolicy)];

  // Accumulators
  let totalTurns = 0;
  let totalToolCalls = 0;
  const toolBreakdown: Record<string, number> = {};
  let success = true;
  let errorMessage: string | undefined;
  const textChunks: string[] = [];
  const pendingToolCalls = new Map<string, { toolName: string; args: Record<string, unknown> }>();
  const phaseTrace = opts.observability ? createPhaseTrace(opts.observability) : undefined;
  // Track control outcome from phase control tools (ask_operator, abort_phase, needs_retry)
  let controlOutcome: import("./pi-sdk-tools.js").ControlOutcome | undefined;

  const writeLog = (line: string): void => {
    if (!opts.logFile) return;
    appendFile(opts.logFile, line + "\n").catch(() => { /* non-fatal */ });
  };

  const safeEmitStreamEvent = (event: StreamEvent): void => {
    try {
      opts.onStreamEvent?.(event);
    } catch (err) {
      writeLog(`[pi-sdk-runner] onStreamEvent error: ${err instanceof Error ? err.message : String(err)}`);
    }
  };

  try {
    // Explicitly set agentDir and auth so detached worker processes find credentials.
    const agentDir = getAgentDir();
    const authStorage = AuthStorage.create(join(agentDir, "auth.json"));
    const sandboxPiExtensions = shouldSandboxPiExtensions();
    const sandboxResources = sandboxPiExtensions ? getSandboxedPiResourcePaths() : undefined;
    const extensionFactories = [
      createSystemPromptExtension(opts.systemPrompt),
      createLegacySlashPromptAliasExtension(),
      phaseTrace ? createPiObservabilityExtensionWithEmitter(phaseTrace, opts.onTraceEvent) : undefined,
    ].filter((factory): factory is ExtensionFactory => Boolean(factory));

    const resourceLoader = new DefaultResourceLoader({
      cwd: opts.cwd,
      agentDir,
      settingsManager: SettingsManager.create(opts.cwd, agentDir),
      noExtensions: sandboxPiExtensions,
      noSkills: sandboxPiExtensions,
      noPromptTemplates: sandboxPiExtensions,
      additionalExtensionPaths: sandboxResources?.extensionPaths,
      additionalSkillPaths: sandboxResources?.skillPaths,
      additionalPromptTemplatePaths: sandboxResources?.promptTemplatePaths,
      extensionFactories,
    });
    await resourceLoader.reload();

    const { session } = await createAgentSession({
      cwd: opts.cwd,
      agentDir,
      authStorage,
      model,
      thinkingLevel: "medium",
      tools,
      customTools,
      resourceLoader,
      sessionManager: SessionManager.inMemory(),
      settingsManager: SettingsManager.create(opts.cwd, agentDir),
    });

    let maxTurnsExceeded = false;
    let maxTurnAbortRequested = false;
    const requestMaxTurnAbort = (): void => {
      const maxTurns = opts.maxTurns;
      if (!maxTurns || totalTurns < maxTurns || maxTurnAbortRequested) return;
      maxTurnAbortRequested = true;
      maxTurnsExceeded = true;
      success = false;
      errorMessage = `Phase exceeded maxTurns (${maxTurns})`;
      void session.abort().catch((err: unknown) => {
        const message = err instanceof Error ? err.message : String(err);
        writeLog(`[pi-sdk-runner] maxTurns abort failed: ${message}`);
      });
    };

    // Subscribe to events for tracking
    session.subscribe((event: AgentSessionEvent) => {
      const eventError = getPiSdkEventError(event);
      if (eventError) {
        success = false;
        errorMessage = eventError;
      }

      const timestamp = new Date().toISOString();

      switch (event.type) {
        case "turn_start":
          totalTurns++;
          safeEmitStreamEvent({
            type: "turnStart",
            iteration: totalTurns,
            timestamp,
          });
          break;

        case "turn_end": {
          opts.onTurnEnd?.(totalTurns);
          const stats = session.getSessionStats();
          safeEmitStreamEvent({
            type: "turnEnd",
            iteration: totalTurns,
            timestamp,
            tokensIn: stats.tokens?.input,
            tokensOut: stats.tokens?.output,
          });
          requestMaxTurnAbort();
          break;
        }

        case "message_update": {
          // Capture assistant text deltas
          const updateEvent = event as Record<string, unknown>;
          const assistantEvent = updateEvent.assistantMessageEvent as Record<string, unknown> | undefined;
          if (assistantEvent?.type === "text_delta") {
            const delta = assistantEvent.delta as string | undefined;
            if (delta) {
              textChunks.push(delta);
              opts.onText?.(delta);
              safeEmitStreamEvent({
                type: "text",
                iteration: totalTurns,
                timestamp,
                delta,
              });
            }
          }
          break;
        }

        case "tool_execution_start": {
          const rawEvent = event as Record<string, unknown>;
          const toolName = rawEvent.toolName as string | undefined;
          if (toolName) {
            totalToolCalls++;
            toolBreakdown[toolName] = (toolBreakdown[toolName] ?? 0) + 1;
            const toolCallId = rawEvent.toolCallId as string | undefined;
            const input = rawEvent.args as Record<string, unknown> | undefined;
            if (toolCallId) pendingToolCalls.set(toolCallId, { toolName, args: input ?? {} });
            opts.onToolCall?.(toolName, input ?? {});
            safeEmitStreamEvent({
              type: "toolCall",
              iteration: totalTurns,
              timestamp,
              toolCallId,
              toolName,
              args: input ?? {},
            });
          }
          break;
        }

        case "tool_execution_end": {
          const rawEvent = event as Record<string, unknown>;
          const toolCallId = rawEvent.toolCallId as string | undefined;
          const pending = toolCallId ? pendingToolCalls.get(toolCallId) : undefined;
          if (toolCallId) pendingToolCalls.delete(toolCallId);
          const toolName = (rawEvent.toolName as string | undefined) ?? pending?.toolName;
          if (toolName) {
            // Track control outcomes from phase control tools
            const result = rawEvent.result as { controlOutcome?: import("./pi-sdk-tools.js").ControlOutcome } | undefined;
            if (result?.controlOutcome && !controlOutcome) {
              controlOutcome = result.controlOutcome;
            }
            safeEmitStreamEvent({
              type: "toolCallFinished",
              iteration: totalTurns,
              timestamp,
              toolCallId,
              toolName,
              args: pending?.args,
              result: rawEvent.result,
              isError: rawEvent.isError === true,
            });
          }
          break;
        }

        case "agent_end": {
          const endEvent = event as Record<string, unknown>;
          if (endEvent.success === false) {
            success = false;
            errorMessage = (endEvent.message as string) ?? "Agent ended without success";
          }
          safeEmitStreamEvent({
            type: "agentEnd",
            iteration: totalTurns,
            timestamp,
            success: endEvent.success !== false,
            message: endEvent.message as string | undefined,
          });
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

    // Send the prompt and await completion. System instructions are injected
    // through a before_agent_start extension so slash prompt expansion still
    // sees the user's command at the beginning of the input.
    try {
      await session.prompt(opts.prompt);
    } catch (err: unknown) {
      if (!maxTurnsExceeded) {
        success = false;
        errorMessage = err instanceof Error ? err.message : String(err);
      }
    }

    // Extract cost and token usage from session stats
    const stats = session.getSessionStats();
    const costUsd = stats.cost ?? 0;
    const tokensIn = stats.tokens?.input ?? 0;
    const tokensOut = stats.tokens?.output ?? 0;

    // Clean up
    session.dispose();

    writeLog(
      `[pi-sdk-runner] success=${success} turns=${totalTurns} maxTurns=${opts.maxTurns ?? "none"} tools=${totalToolCalls} cost=$${costUsd.toFixed(4)} tokensIn=${tokensIn} tokensOut=${tokensOut}`, 
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
        taskId: phaseTrace.taskId,
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
      ...(() => {
        if (!opts.output) return {};
        const extracted = extractStructuredOutput(
          textChunks.length > 0 ? textChunks.join("") : undefined,
          opts.output,
        );
        return {
          output: extracted.output,
          outputError: extracted.error,
        };
      })(),
      traceFile: tracePaths?.relativeJsonPath,
      traceMarkdownFile: tracePaths?.relativeMarkdownPath,
      traceWarnings: phaseTrace?.warnings,
      commandHonored: phaseTrace?.commandHonored,
      controlOutcome,
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
        taskId: phaseTrace.taskId,
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
      ...(() => {
        if (!opts.output) return {};
        const extracted = extractStructuredOutput(
          textChunks.length > 0 ? textChunks.join("") : undefined,
          opts.output,
        );
        return {
          output: extracted.output,
          outputError: extracted.error,
        };
      })(),
      traceFile: tracePaths?.relativeJsonPath,
      traceMarkdownFile: tracePaths?.relativeMarkdownPath,
      traceWarnings: phaseTrace?.warnings,
      commandHonored: phaseTrace?.commandHonored,
      controlOutcome,
    };
  }
}
