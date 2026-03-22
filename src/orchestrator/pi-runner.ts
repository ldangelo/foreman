/**
 * pi-runner.ts — Shared utility for running Pi synchronously (awaitable).
 *
 * This replaces the `query()` async generator from the Claude Agent SDK for
 * agent-worker.ts pipeline phases. Pi is run as a foreground process (NOT
 * detached) so each phase awaits completion before proceeding.
 *
 * Pi communicates via JSONL over stdin/stdout:
 *   stdin  ← {"type":"prompt","message":"..."}
 *   stdout → {"type":"agent_start"} ... {"type":"agent_end","success":true}
 */

import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { appendFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";

// ── Pi binary resolution ──────────────────────────────────────────────────

const PI_BINARY_FALLBACK = "/opt/homebrew/bin/pi";

/**
 * Resolve the Pi binary path.
 * Respects FOREMAN_PI_BIN env override, then PATH via `which`, then fallback.
 */
function resolvePiBinary(): string {
  if (process.env.FOREMAN_PI_BIN) return process.env.FOREMAN_PI_BIN;
  try {
    const result = execFileSync("which", ["pi"], { encoding: "utf-8" }).trim();
    if (result) return result;
  } catch {
    // fall through
  }
  return PI_BINARY_FALLBACK;
}

// ── Pi JSONL event types ──────────────────────────────────────────────────

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
  usage?: { input_tokens: number; output_tokens: number };
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

interface PiEventExtensionUiRequest {
  type: "extension_ui_request";
  subtype?: string;
  [key: string]: unknown;
}

interface PiEventError {
  type: "error";
  message: string;
}

type PiEvent =
  | PiEventAgentStart
  | PiEventTurnStart
  | PiEventTurnEnd
  | PiEventToolCall
  | PiEventToolResult
  | PiEventAgentEnd
  | PiEventExtensionUiRequest
  | PiEventError;

/**
 * Parse a single line of Pi JSONL stdout into a typed event.
 * Returns null when the line is empty, not valid JSON, or has an unknown type.
 */
function parsePiEvent(line: string): PiEvent | null {
  const trimmed = line.trim();
  if (!trimmed) return null;
  try {
    const obj = JSON.parse(trimmed) as Record<string, unknown>;
    if (typeof obj.type !== "string") return null;
    return obj as unknown as PiEvent;
  } catch {
    return null;
  }
}

// ── Public interface ──────────────────────────────────────────────────────

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
  model: string;
  env: Record<string, string>;
  logFile?: string;
  onToolCall?: (name: string, input: Record<string, unknown>) => void;
  onTurnEnd?: (turn: number) => void;
}

// Token pricing constants (approximate Anthropic pricing per million tokens)
// Used to estimate cost from token counts when Pi doesn't report cost directly.
const COST_PER_INPUT_TOKEN = 3.0 / 1_000_000;   // ~$3/M input
const COST_PER_OUTPUT_TOKEN = 15.0 / 1_000_000;  // ~$15/M output

/**
 * Run a single Pi session synchronously (awaits agent_end before resolving).
 *
 * Spawns `pi --mode rpc` as a foreground (non-detached) process, sends the
 * prompt over stdin, reads JSONL events from stdout, and resolves when the
 * agent_end event arrives or the process exits.
 *
 * @returns PiRunResult with success/failure, cost estimate, and tool usage stats.
 */
export async function runWithPi(opts: PiRunOptions): Promise<PiRunResult> {
  const piBin = resolvePiBinary();

  // Build clean env: inherit opts.env, strip CLAUDECODE
  const piEnv: Record<string, string> = {};
  for (const [k, v] of Object.entries(opts.env)) {
    if (k !== "CLAUDECODE") piEnv[k] = v;
  }

  const piArgs = ["--mode", "rpc", "--provider", "anthropic", "--model", opts.model];

  const child = spawn(piBin, piArgs, {
    stdio: ["pipe", "pipe", "pipe"],
    cwd: opts.cwd,
    env: piEnv,
    // NOT detached — we await completion
  });

  // Send prompt to stdin then close it.
  // Note: set_context is not yet supported by Pi; we skip it and just send the prompt.
  if (child.stdin) {
    const promptMsg = JSON.stringify({ type: "prompt", message: opts.prompt });
    child.stdin.write(promptMsg + "\n");
    child.stdin.end();
  }

  // Accumulators
  let agentEndReceived = false;
  let agentEndSuccess = true;
  let agentEndMessage: string | undefined;
  let totalTurns = 0;
  let totalToolCalls = 0;
  const toolBreakdown: Record<string, number> = {};
  let estimatedCostUsd = 0;
  let totalInputTokens = 0;
  let totalOutputTokens = 0;

  // Write a log entry (fire-and-forget, non-fatal)
  const writeLog = (line: string): void => {
    if (!opts.logFile) return;
    appendFile(opts.logFile, line + "\n").catch(() => { /* non-fatal */ });
  };

  // Read Pi stdout JSONL line by line
  await new Promise<void>((resolve) => {
    if (!child.stdout) {
      resolve();
      return;
    }

    const rl = createInterface({ input: child.stdout, crlfDelay: Infinity });

    rl.on("line", (line) => {
      // Log raw line
      writeLog(line);

      const event = parsePiEvent(line);
      if (!event) return;

      switch (event.type) {
        case "agent_start":
          // Session started — no action needed
          break;

        case "turn_start":
          // Turn beginning — no action needed
          break;

        case "turn_end": {
          totalTurns = event.turn;
          if (event.usage) {
            totalInputTokens += event.usage.input_tokens;
            totalOutputTokens += event.usage.output_tokens;
            estimatedCostUsd +=
              event.usage.input_tokens * COST_PER_INPUT_TOKEN +
              event.usage.output_tokens * COST_PER_OUTPUT_TOKEN;
          }
          opts.onTurnEnd?.(event.turn);
          break;
        }

        case "tool_call": {
          totalToolCalls++;
          toolBreakdown[event.name] = (toolBreakdown[event.name] ?? 0) + 1;
          opts.onToolCall?.(event.name, event.input);
          break;
        }

        case "tool_result":
          // Tool results are informational — no accumulation needed
          break;

        case "agent_end": {
          agentEndReceived = true;
          // Treat absence of `success: false` as success (Pi may omit the field)
          agentEndSuccess = event.success !== false;
          agentEndMessage = event.message;
          break;
        }

        case "extension_ui_request":
          // Ignore these events — they are UI hints, not agent protocol
          break;

        case "error": {
          agentEndReceived = true;
          agentEndSuccess = false;
          agentEndMessage = event.message;
          break;
        }
      }
    });

    rl.on("close", () => {
      resolve();
    });

    rl.on("error", () => {
      resolve();
    });
  });

  // Wait for the process to exit
  const exitCode = await new Promise<number | null>((resolve) => {
    if (child.exitCode !== null) {
      resolve(child.exitCode);
      return;
    }
    child.on("close", (code) => resolve(code));
    child.on("error", () => resolve(null));
  });

  // Determine final success:
  // - exit code 0 (or null/unset) is generally success
  // - agent_end with success:false is explicit failure
  // - error event is explicit failure
  const explicitFailure = agentEndReceived && !agentEndSuccess;
  const success = (exitCode === 0 || exitCode === null) && !explicitFailure;

  writeLog(
    `[pi-runner] agent_end=${agentEndReceived} exitCode=${exitCode ?? "null"} success=${success} turns=${totalTurns} tools=${totalToolCalls} estimatedCost=$${estimatedCostUsd.toFixed(4)}`,
  );

  return {
    success,
    costUsd: estimatedCostUsd,
    turns: totalTurns,
    toolCalls: totalToolCalls,
    toolBreakdown,
    errorMessage: success ? undefined : (agentEndMessage ?? `Pi exited with code ${exitCode ?? "null"}`),
  };
}
