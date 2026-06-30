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
import { type AgentSessionEvent, type ToolDefinition } from "@mariozechner/pi-coding-agent";
import { type GuardrailConfig } from "./guardrails.js";
import type { PhaseTraceLiveEvent, PhaseTraceMetadata } from "./pi-observability-types.js";
import { z } from "zod";
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
}
/**
 * Normalized stream event types for the onStreamEvent callback.
 * These provide a simplified, stable API surface over raw Pi SDK events.
 */
export type StreamEvent = {
    type: "text";
    iteration: number;
    timestamp: string;
    delta: string;
} | {
    type: "toolCall";
    iteration: number;
    timestamp: string;
    toolName: string;
    args: Record<string, unknown>;
} | {
    type: "turnStart";
    iteration: number;
    timestamp: string;
} | {
    type: "turnEnd";
    iteration: number;
    timestamp: string;
    tokensIn?: number;
    tokensOut?: number;
} | {
    type: "agentEnd";
    iteration: number;
    timestamp: string;
    success: boolean;
    message?: string;
};
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
    /** Live observability callback fired from Pi extension hooks. */
    onTraceEvent?: (event: PhaseTraceLiveEvent) => void;
    /** Optional structured output extraction. When provided, the runner will extract and validate JSON from outputText. */
    output?: StructuredOutputOptions;
}
export declare function shouldSandboxPiExtensions(env?: NodeJS.ProcessEnv): boolean;
export interface SandboxedPiResourcePaths {
    extensionPaths: string[];
    skillPaths: string[];
    promptTemplatePaths: string[];
}
export declare function getSandboxedPiResourcePaths(env?: NodeJS.ProcessEnv): SandboxedPiResourcePaths;
export declare function normalizeLegacySlashPrompt(prompt: string): string;
/**
 * Run a single Pi SDK session (awaits completion before resolving).
 *
 * Creates an in-memory AgentSession, sends the prompt, listens for events
 * to track tool calls / turns / cost, and resolves with structured results.
 */
export declare function getPiSdkEventError(event: AgentSessionEvent): string | undefined;
/**
 * Extract and validate structured output from agent text.
 * Looks for content between <tag>...</tag> markers, parses as JSON,
 * and validates against the provided Zod schema.
 *
 * Returns an object with either `output` (validated data) or `error` (failure message).
 * Does not throw — all errors are captured in the return value.
 */
export declare function extractStructuredOutput(outputText: string | undefined, options: StructuredOutputOptions): {
    output?: unknown;
    error?: string;
};
export declare function runWithPiSdk(opts: PiRunOptions): Promise<PiRunResult>;
//# sourceMappingURL=pi-sdk-runner.d.ts.map