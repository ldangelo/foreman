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
import { createInterface } from "node:readline";
import { mkdir } from "node:fs/promises";
import { open } from "node:fs/promises";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import type { SpawnStrategy, SpawnResult, WorkerConfig } from "./dispatcher.js";
import { AgentMailClient } from "./agent-mail-client.js";

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
  // Allow tests (and advanced users) to override the binary path via env var.
  if (process.env.FOREMAN_PI_BIN) return process.env.FOREMAN_PI_BIN;
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

    // Resolve project path using same pattern as agent-worker.ts
    const projectPath = config.projectPath ?? join(config.worktreePath, "..", "..");

    // Prepare log directory
    const logDir = join(process.env.HOME ?? "/tmp", ".foreman", "logs");
    await mkdir(logDir, { recursive: true });
    // stdout is piped (not redirected to fd) so we can read JSONL events — we
    // manually tee each line to the .out log file ourselves.
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

    // stdout is "pipe" so we can read JSONL lines; we tee each line to the log file.
    const child = spawn(piBin, ["--mode", "rpc"], {
      detached: true,
      stdio: ["pipe", "pipe", errFd.fd],
      cwd: config.worktreePath,
      env: cleanEnv,
    });

    child.unref();

    // Close the error fd handle in the parent after the child has inherited it.
    // We keep outFd open until the background task finishes writing.
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

    // ── Background task: read JSONL stdout, tee to log, send Agent Mail on completion ──
    // This runs fire-and-forget — spawn() returns immediately.
    void (async () => {
      // Set up Agent Mail client.  All failures are silent.
      let agentMailClient: AgentMailClient | null = null;
      try {
        const candidate = new AgentMailClient();
        const reachable = await candidate.healthCheck();
        if (reachable) {
          await candidate.ensureProject(projectPath);
          // Register this phase as a named sending identity
          const phaseRoleHint = `${phase}-${config.seedId}`;
          const generatedName = await candidate.ensureAgentRegistered(phaseRoleHint, projectPath);
          if (generatedName) {
            candidate.agentName = generatedName;
            log(`[agent-mail] Pi phase registered as '${generatedName}' (role: ${phaseRoleHint})`);
          }
          agentMailClient = candidate;
        }
      } catch {
        // Silent failure — Agent Mail is optional
      }

      // Read Pi stdout JSONL, tee each line to the .out log file.
      let agentEndReceived = false;
      let agentEndSuccess = true;
      let agentEndMessage: string | undefined;

      try {
        if (child.stdout) {
          const rl = createInterface({ input: child.stdout, crlfDelay: Infinity });
          for await (const line of rl) {
            // Tee to log file
            try {
              await outFd.write(line + "\n");
            } catch {
              // Non-fatal log write failure
            }

            const event = parsePiEvent(line);
            if (!event) continue;

            if (event.type === "agent_end") {
              agentEndReceived = true;
              // Real Pi emits agent_end without a `success` field on normal completion.
              // Treat absence of `success: false` as success.
              agentEndSuccess = event.success !== false;
              agentEndMessage = event.message;
            }
          }
        }
      } catch {
        // stdout read failure — treat as error
        agentEndSuccess = false;
      }

      // Wait for child exit
      const exitCode = await new Promise<number | null>((resolve) => {
        child.on("close", (code) => resolve(code));
        // If already exited (no stdout), resolve immediately
        if (child.exitCode !== null) resolve(child.exitCode);
      });

      // Close the log file handle now that we're done writing
      try {
        await outFd.close();
      } catch {
        // Non-fatal
      }

      // Determine success: exit code 0 = success unless agent_end explicitly
      // signals failure (success: false). Not receiving agent_end is not an error
      // — Pi may not emit it in all cases (e.g. budget-exceeded short-circuits).
      const explicitFailure = agentEndReceived && !agentEndSuccess;
      const success = (exitCode === 0 || exitCode === null) && !explicitFailure;

      log(
        `[pi-rpc] Phase ${phase} for ${config.seedId} finished: ` +
          `success=${success} exitCode=${exitCode ?? "null"} ` +
          `agent_end=${agentEndReceived}`,
      );

      // Send Agent Mail phase lifecycle message to "foreman"
      if (agentMailClient) {
        try {
          if (success) {
            await agentMailClient.sendMessage(
              "foreman",
              "phase-complete",
              JSON.stringify({
                seedId: config.seedId,
                phase,
                runId: config.runId,
                status: "complete",
              }),
            );
            log(`[agent-mail] Sent phase-complete for ${phase}/${config.seedId}`);
          } else {
            await agentMailClient.sendMessage(
              "foreman",
              "agent-error",
              JSON.stringify({
                seedId: config.seedId,
                phase,
                runId: config.runId,
                status: "error",
                message: agentEndMessage ?? `Pi exited with code ${exitCode ?? "null"}`,
              }),
            );
            log(`[agent-mail] Sent agent-error for ${phase}/${config.seedId}`);
          }
        } catch {
          // Silent failure — mail errors must never surface
        }
      }
    })();

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
