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
import { mkdir, readFile } from "node:fs/promises";
import { open } from "node:fs/promises";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import Database from "better-sqlite3";
import type { SpawnStrategy, SpawnResult, WorkerConfig } from "./dispatcher.js";
import { SqliteMailClient } from "../lib/sqlite-mail-client.js";
import { ForemanStore } from "../lib/store.js";
import {
  loadWorkflowConfig,
  resolveWorkflowName,
  getWorkflowPhase,
  resolveWorkflowModel,
} from "../lib/workflow-loader.js";

// ── Pi phase configuration ───────────────────────────────────────────────

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
const FALLBACK_PHASE_MODELS: Readonly<Record<string, string>> = {
  explorer: "anthropic/claude-haiku-4-5",
  developer: "anthropic/claude-sonnet-4-6",
  qa: "anthropic/claude-sonnet-4-6",
  reviewer: "anthropic/claude-sonnet-4-6",
  finalize: "anthropic/claude-haiku-4-5",
};

export const PI_PHASE_CONFIGS: Readonly<Record<string, PiPhaseConfig>> = {
  explorer: {
    allowedTools: ["Read", "Grep", "Glob", "LS", "WebFetch", "WebSearch"],
    maxTurns: 30,
    maxTokens: 100_000,
  },
  developer: {
    allowedTools: ["Read", "Write", "Edit", "Bash", "Grep", "Glob", "LS"],
    maxTurns: 80,
    maxTokens: 500_000,
  },
  qa: {
    allowedTools: ["Read", "Grep", "Glob", "LS", "Bash"],
    maxTurns: 30,
    maxTokens: 200_000,
  },
  reviewer: {
    allowedTools: ["Read", "Grep", "Glob", "LS"],
    maxTurns: 20,
    maxTokens: 150_000,
  },
  finalize: {
    allowedTools: ["Read", "Write", "Edit", "Bash", "Grep", "Glob", "LS"],
    maxTurns: 20,
    maxTokens: 200_000,
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
 * Resolve the Anthropic API key for Pi.
 * Priority: ANTHROPIC_API_KEY env var → /run/secrets/anthropic_api_key file.
 * If neither is available, returns empty string and Pi will use its own auth.json.
 */
async function resolveAnthropicApiKey(env: Record<string, string>): Promise<string> {
  if (env.ANTHROPIC_API_KEY) return env.ANTHROPIC_API_KEY;
  // Try secrets file (NixOS / home-manager pattern)
  try {
    const key = (await readFile("/run/secrets/anthropic_api_key", "utf-8")).trim();
    if (key) return key;
  } catch {
    // not available
  }
  return "";
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
    const phaseConfig = PI_PHASE_CONFIGS[phase] ?? PI_PHASE_CONFIGS["developer"]!;

    // Resolve project path using same pattern as agent-worker.ts
    const projectPath = config.projectPath ?? join(config.worktreePath, "..", "..");

    // Resolve phase model from workflow config; fall back to per-phase defaults.
    let phaseModel: string = FALLBACK_PHASE_MODELS[phase] ?? FALLBACK_PHASE_MODELS["developer"]!;
    try {
      const workflowName = resolveWorkflowName(config.seedType ?? "feature", config.seedLabels);
      const workflowConfig = loadWorkflowConfig(workflowName, projectPath);
      const workflowPhase = getWorkflowPhase(workflowConfig, phase);
      phaseModel = resolveWorkflowModel(workflowPhase?.model) ?? phaseModel;
    } catch {
      // Workflow config unavailable — use fallback model
    }

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
      // Pi extensions to load
      PI_EXTENSIONS: "foreman-tool-gate,foreman-budget,foreman-audit",
    };

    // Remove undefined entries — spawn env must be string | undefined but
    // we clean it here so downstream code is unambiguous.
    const cleanEnv: Record<string, string> = {};
    for (const [k, v] of Object.entries(piEnv)) {
      if (v !== undefined) cleanEnv[k] = v;
    }

    // Resolve the Anthropic API key and inject it into the Pi environment.
    // Pi reads ANTHROPIC_API_KEY from its process env; passing it explicitly
    // ensures it works even when the parent shell didn't export it.
    const anthropicApiKey = await resolveAnthropicApiKey(cleanEnv);
    if (anthropicApiKey) {
      cleanEnv.ANTHROPIC_API_KEY = anthropicApiKey;
    }

    // Build pi args: always use Anthropic provider with the phase model
    const piArgs = ["--mode", "rpc", "--provider", "anthropic", "--model", phaseModel];

    log(`Spawning pi --mode rpc for ${config.seedId} phase=${phase} in ${config.worktreePath}`);

    // stdout is "pipe" so we can read JSONL lines; we tee each line to the log file.
    const child = spawn(piBin, piArgs, {
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
        systemPrompt: buildSystemPrompt(config, phase, phaseConfig, phaseModel),
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

    // ── Background task: read JSONL stdout, tee to log, send SQLite mail on completion ──
    // This runs fire-and-forget — spawn() returns immediately.
    void (async () => {
      // Set up SQLite mail client. All failures are silent.
      let agentMailClient: SqliteMailClient | null = null;
      try {
        const sqliteClient = new SqliteMailClient();
        await sqliteClient.ensureProject(projectPath);
        sqliteClient.setRunId(config.runId);
        const phaseRoleHint = `${phase}-${config.seedId}`;
        await sqliteClient.ensureAgentRegistered(phaseRoleHint);
        agentMailClient = sqliteClient;
        log(`[agent-mail] Pi phase using SqliteMailClient (role: ${phaseRoleHint})`);
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

      // Update SQLite run status so the merge queue can find the completed run.
      if (config.dbPath) {
        try {
          const db = new Database(config.dbPath);
          const now = new Date().toISOString();
          db.prepare(
            "UPDATE runs SET status = ?, completed_at = ? WHERE id = ? AND status = 'running'",
          ).run(success ? "completed" : "failed", now, config.runId);
          db.close();
          log(`[sqlite] Marked run ${config.runId} as ${success ? "completed" : "failed"}`);
        } catch (err) {
          log(`[sqlite] Failed to update run status: ${err}`);
        }
      }

      // Send SQLite mail phase lifecycle message to "foreman"
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
  phaseModel: string,
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
    `Model: ${phaseModel}`,
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
