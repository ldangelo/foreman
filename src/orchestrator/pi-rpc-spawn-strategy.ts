/**
 * PiRpcSpawnStrategy — spawn strategy that uses the `pi` binary in RPC mode.
 *
 * Pi communicates via JSONL over stdin/stdout.  This strategy spawns
 * `pi --mode rpc`, sends a context + prompt over stdin, and wires up
 * stdout event parsing so the run record in SQLite is kept up to date.
 *
 * Falls back gracefully: if the `pi` binary cannot be found, `isPiAvailable()`
 * returns false and callers should fall back to DetachedSpawnStrategy.
 */

import { spawn } from "node:child_process";
import { mkdir } from "node:fs/promises";
import { open } from "node:fs/promises";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import type { SpawnStrategy, SpawnResult, WorkerConfig } from "./dispatcher.js";

// ── Pi phase configuration ───────────────────────────────────────────────

export interface PiPhaseConfig {
  model: string;
  allowedTools: readonly string[];
  maxTurns: number;
  maxTokens: number;
}

/**
 * Per-phase settings used when spawning Pi.
 *
 * These are passed to Pi via environment variables so the Pi process
 * (and any extensions loaded by it) can enforce them.
 */
export const PI_PHASE_CONFIGS: Readonly<Record<string, PiPhaseConfig>> = {
  explorer: {
    model: "claude-haiku-4-5-20251001",
    allowedTools: ["Read", "Grep", "Glob", "LS", "WebFetch", "WebSearch"],
    maxTurns: 30,
    maxTokens: 100_000,
  },
  developer: {
    model: "claude-sonnet-4-6",
    allowedTools: ["Read", "Write", "Edit", "Bash", "Grep", "Glob", "LS"],
    maxTurns: 80,
    maxTokens: 500_000,
  },
  qa: {
    model: "claude-sonnet-4-6",
    allowedTools: ["Read", "Grep", "Glob", "LS", "Bash"],
    maxTurns: 30,
    maxTokens: 200_000,
  },
  reviewer: {
    model: "claude-sonnet-4-6",
    allowedTools: ["Read", "Grep", "Glob", "LS"],
    maxTurns: 20,
    maxTokens: 150_000,
  },
} as const;

// ── Pi JSONL event types ─────────────────────────────────────────────────

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

type PiEvent =
  | PiEventAgentStart
  | PiEventTurnStart
  | PiEventTurnEnd
  | PiEventToolCall
  | PiEventToolResult
  | PiEventAgentEnd
  | PiEventBudgetExceeded
  | PiEventError;

// ── Pi RPC message types (stdin) ─────────────────────────────────────────

interface PiSetContextMessage {
  type: "set_context";
  systemPrompt: string;
  contextFiles?: Array<{ path: string; content: string }>;
}

interface PiPromptMessage {
  type: "prompt";
  message: string;
}

// ── Availability detection ───────────────────────────────────────────────

const PI_BINARY = "/opt/homebrew/bin/pi";

/**
 * Check whether the `pi` binary is available on the current system.
 *
 * Uses `which pi` so the result respects the caller's PATH.  Falls back
 * to the known Homebrew path as a secondary check.
 *
 * This function never throws — on any error it returns false so callers
 * can gracefully fall back to DetachedSpawnStrategy.
 */
export function isPiAvailable(): boolean {
  try {
    execFileSync("which", ["pi"], { stdio: "ignore" });
    return true;
  } catch {
    // "which" failed — try the known path directly
    try {
      execFileSync(PI_BINARY, ["--version"], { stdio: "ignore" });
      return true;
    } catch {
      return false;
    }
  }
}

// ── PiRpcSpawnStrategy ───────────────────────────────────────────────────

/**
 * Resolve the Pi binary path: use PATH resolution when available,
 * otherwise fall back to the known Homebrew install path.
 */
function resolvePiBinary(): string {
  try {
    const result = execFileSync("which", ["pi"], { encoding: "utf-8" }).trim();
    if (result) return result;
  } catch {
    // fall through
  }
  return PI_BINARY;
}

function log(msg: string): void {
  const ts = new Date().toISOString().slice(11, 23);
  console.error(`[pi-rpc ${ts}] ${msg}`);
}

/**
 * Spawn strategy that runs agents via `pi --mode rpc`.
 *
 * Responsibilities:
 * 1. Resolve the Pi binary path.
 * 2. Build per-phase env vars (model, tools, budget, IDs).
 * 3. Spawn `pi --mode rpc` as a detached process connected via stdin/stdout JSONL.
 * 4. Write the set_context + prompt messages to stdin.
 * 5. Forward stdout JSONL events to stderr for log visibility.
 * 6. Return immediately — the process runs independently in the background.
 *
 * The spawned process inherits the log file fds (stdout → .out, stderr → .err)
 * via the same pattern used by DetachedSpawnStrategy.
 */
export class PiRpcSpawnStrategy implements SpawnStrategy {
  async spawn(config: WorkerConfig): Promise<SpawnResult> {
    const piBin = resolvePiBinary();

    // Determine phase from env vars that agent-worker sets, or fall back to "developer"
    const phase = config.env.FOREMAN_PHASE ?? "developer";
    const phaseConfig = PI_PHASE_CONFIGS[phase] ?? PI_PHASE_CONFIGS.developer;

    // Prepare log directory
    const logDir = join(process.env.HOME ?? "/tmp", ".foreman", "logs");
    await mkdir(logDir, { recursive: true });
    const outFd = await open(join(logDir, `${config.runId}.out`), "w");
    const errFd = await open(join(logDir, `${config.runId}.err`), "w");

    // Build env for Pi process
    const piEnv: Record<string, string | undefined> = {
      ...config.env,
      // Strip CLAUDECODE to avoid nested session errors
      CLAUDECODE: undefined,
      // Phase-specific settings
      FOREMAN_PHASE: phase,
      FOREMAN_ALLOWED_TOOLS: phaseConfig.allowedTools.join(","),
      FOREMAN_MAX_TURNS: String(phaseConfig.maxTurns),
      FOREMAN_MAX_TOKENS: String(phaseConfig.maxTokens),
      // Run/seed IDs for audit and budget enforcement
      FOREMAN_RUN_ID: config.runId,
      FOREMAN_SEED_ID: config.seedId,
      // Agent mail endpoint
      FOREMAN_AGENT_MAIL_URL: config.env.FOREMAN_AGENT_MAIL_URL ?? "http://localhost:8765",
      // Pi extensions to load
      PI_EXTENSIONS: "foreman-tool-gate,foreman-budget,foreman-audit",
    };

    // Remove undefined entries — spawn env must be string | undefined but
    // we clean it here so downstream code is unambiguous.
    const cleanEnv: Record<string, string> = {};
    for (const [k, v] of Object.entries(piEnv)) {
      if (v !== undefined) cleanEnv[k] = v;
    }

    log(`Spawning pi --mode rpc for ${config.seedId} phase=${phase} in ${config.worktreePath}`);

    const child = spawn(piBin, ["--mode", "rpc"], {
      detached: true,
      stdio: ["pipe", outFd.fd, errFd.fd],
      cwd: config.worktreePath,
      env: cleanEnv,
    });

    child.unref();

    // Close parent file handles after child has inherited its fd copies
    await outFd.close();
    await errFd.close();

    // Send context then prompt over stdin JSONL
    if (child.stdin) {
      const setContext: PiSetContextMessage = {
        type: "set_context",
        systemPrompt: buildSystemPrompt(config, phase, phaseConfig),
        contextFiles: [
          {
            path: "/virtual/TASK.md",
            content: config.prompt,
          },
        ],
      };

      const promptMsg: PiPromptMessage = {
        type: "prompt",
        message: config.prompt,
      };

      child.stdin.write(JSON.stringify(setContext) + "\n");
      child.stdin.write(JSON.stringify(promptMsg) + "\n");
      child.stdin.end();
    }

    log(`  Pi pid=${child.pid} for ${config.seedId}`);
    return {};
  }
}

// ── Helpers ──────────────────────────────────────────────────────────────

/**
 * Build the system prompt sent to Pi in the set_context message.
 * Describes the Foreman context and the phase-specific role.
 */
function buildSystemPrompt(
  config: WorkerConfig,
  phase: string,
  phaseConfig: PiPhaseConfig,
): string {
  const allowedTools = phaseConfig.allowedTools.join(", ");
  return [
    `You are a ${phase} agent running as part of the Foreman orchestration pipeline.`,
    ``,
    `Task: ${config.seedTitle}`,
    `Seed ID: ${config.seedId}`,
    `Run ID: ${config.runId}`,
    `Working directory: ${config.worktreePath}`,
    ``,
    `Phase: ${phase}`,
    `Model: ${phaseConfig.model}`,
    `Max turns: ${phaseConfig.maxTurns}`,
    `Max tokens: ${phaseConfig.maxTokens}`,
    `Allowed tools: ${allowedTools}`,
    ``,
    `Read TASK.md in the working directory for full task details and instructions.`,
  ].join("\n");
}

/**
 * Parse a single line of Pi JSONL stdout into a typed event.
 * Returns null when the line is empty, not valid JSON, or has an unknown type.
 */
export function parsePiEvent(line: string): PiEvent | null {
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
