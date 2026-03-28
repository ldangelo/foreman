/**
 * Pi availability detection, phase configuration, and JSONL event types.
 *
 * Pi communicates via JSONL over stdin/stdout when invoked as `pi --mode rpc`.
 * This module exports:
 *  - `isPiAvailable()` — check whether the `pi` binary is on PATH
 *  - `PI_PHASE_CONFIGS` — per-phase tool/turn/token limits
 *  - `parsePiEvent()` — parse a single JSONL line from Pi stdout
 *
 * The spawn strategy itself is handled by `DetachedSpawnStrategy` in
 * dispatcher.ts, which spawns agent-worker.ts.  agent-worker.ts calls
 * runWithPi() per phase and injects PI_PHASE_CONFIGS values as env vars
 * so the Pi extensions (foreman-tool-gate, foreman-budget, foreman-audit)
 * can enforce them.
 */
/**
 * Per-phase settings used when spawning Pi.
 *
 * These are passed to Pi via environment variables so the Pi process
 * (and any extensions loaded by it) can enforce them.
 */
export interface PiPhaseConfig {
    allowedTools: readonly string[];
    maxTurns: number;
    maxTokens: number;
}
/** Fallback model per phase — used when workflow config is unavailable. */
export declare const FALLBACK_PHASE_MODELS: Readonly<Record<string, string>>;
export declare const PI_PHASE_CONFIGS: Readonly<Record<string, PiPhaseConfig>>;
interface PiEventAgentStart {
    type: "agent_start";
}
interface PiEventTurnStart {
    type: "turn_start";
    turn: number;
}
interface PiEventTurnEnd {
    type: "turn_end";
    turn: number;
    usage?: {
        input_tokens: number;
        output_tokens: number;
    };
}
interface PiEventToolCall {
    type: "tool_call";
    name: string;
    input: Record<string, unknown>;
}
interface PiEventToolResult {
    type: "tool_result";
    name: string;
    output: string;
}
interface PiEventAgentEnd {
    type: "agent_end";
    success: boolean;
    message?: string;
}
interface PiEventBudgetExceeded {
    type: "extension_ui_request";
    subtype: "budget_exceeded";
    phase?: string;
    limit?: string;
}
interface PiEventError {
    type: "error";
    message: string;
}
export type PiEvent = PiEventAgentStart | PiEventTurnStart | PiEventTurnEnd | PiEventToolCall | PiEventToolResult | PiEventAgentEnd | PiEventBudgetExceeded | PiEventError;
/**
 * Check whether the `pi` binary is available on the current system.
 *
 * Uses `which pi` so the result respects the caller's PATH.  Falls back
 * to the known Homebrew path as a secondary check.
 *
 * This function never throws — on any error it returns false.
 */
export declare function isPiAvailable(): boolean;
/**
 * Parse a single line of Pi JSONL stdout into a typed event.
 * Returns null when the line is empty, not valid JSON, or has an unknown type.
 */
export declare function parsePiEvent(line: string): PiEvent | null;
export {};
//# sourceMappingURL=pi-rpc-spawn-strategy.d.ts.map