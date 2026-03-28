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
import { type ToolDefinition } from "@mariozechner/pi-coding-agent";
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
/**
 * Run a single Pi SDK session (awaits completion before resolving).
 *
 * Creates an in-memory AgentSession, sends the prompt, listens for events
 * to track tool calls / turns / cost, and resolves with structured results.
 */
export declare function runWithPiSdk(opts: PiRunOptions): Promise<PiRunResult>;
//# sourceMappingURL=pi-sdk-runner.d.ts.map