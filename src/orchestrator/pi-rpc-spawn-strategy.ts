import { execFileSync, spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import { PiRpcClient } from "./pi-rpc-client.js";
import type {
  PiAgentStartEvent,
  PiAgentEndEvent,
  PiTurnEndEvent,
  PiToolExecutionStartEvent,
  PiToolExecutionEndEvent,
} from "./pi-rpc-client.js";
import { DetachedSpawnStrategy } from "./dispatcher.js";
import type { SpawnStrategy, SpawnResult, WorkerConfig } from "./dispatcher.js";
import type { ForemanStore, RunProgress } from "../lib/store.js";

// ── Pi Binary Detection ──────────────────────────────────────────────────

/** Valid values for the FOREMAN_SPAWN_STRATEGY environment variable. */
export type SpawnStrategyOverride = "pi-rpc" | "tmux" | "detached";

/**
 * Module-level cache for the pi binary availability check.
 * `null` means "not yet checked". Set to true/false after first check.
 */
let piAvailableCache: boolean | null = null;

/**
 * Reset the module-level cache. Exported for use in unit tests only.
 * Not intended for production use.
 */
export function _resetCache(): void {
  piAvailableCache = null;
}

/**
 * Check if the `pi` binary is available on PATH.
 *
 * Uses `which pi` on unix-like systems or `where pi` on Windows.
 * The result is cached for the lifetime of the process — the binary
 * check is only performed once, regardless of how many times this
 * function is called.
 *
 * @returns `true` if `pi` is found on PATH, `false` otherwise.
 */
export function isPiAvailable(): boolean {
  if (piAvailableCache !== null) {
    return piAvailableCache;
  }

  const cmd = process.platform === "win32" ? "where" : "which";

  try {
    execFileSync(cmd, ["pi"], { stdio: "pipe" });
    piAvailableCache = true;
  } catch {
    piAvailableCache = false;
  }

  return piAvailableCache;
}

/**
 * Select the best spawn strategy for the current environment.
 *
 * Priority:
 * 1. `FOREMAN_SPAWN_STRATEGY` environment variable, when set to a known value
 *    (`"pi-rpc"`, `"tmux"`, `"detached"`).
 * 2. Auto-detection: if `pi` is on PATH → `"pi-rpc"`, otherwise `"detached"`.
 *
 * Unknown values for `FOREMAN_SPAWN_STRATEGY` are ignored and fall through
 * to auto-detection.
 *
 * @returns The strategy name string.
 */
export function selectSpawnStrategy(): SpawnStrategyOverride {
  const override = process.env.FOREMAN_SPAWN_STRATEGY;

  if (override === "pi-rpc" || override === "tmux" || override === "detached") {
    return override;
  }

  // Auto-detect based on pi binary presence
  return isPiAvailable() ? "pi-rpc" : "detached";
}

// ── PiRpcSpawnStrategy ──────────────────────────────────────────────────

/** Timeout for detecting a pipe break after process close (ms). */
const PIPE_BREAK_WINDOW_MS = 5_000;

/**
 * Resolve the path to the foreman-pi-extensions dist/index.js.
 * The extensions package lives at packages/foreman-pi-extensions/ relative
 * to the project root (two directories above this file's compiled location).
 */
function resolveExtensionsPath(): string {
  const __filename = fileURLToPath(import.meta.url);
  const __dirname = dirname(__filename);
  // Compiled: dist/orchestrator/pi-rpc-spawn-strategy.js → project root is ../..
  const projectRoot = join(__dirname, "..", "..");
  return join(projectRoot, "packages", "foreman-pi-extensions", "dist", "index.js");
}

function log(msg: string): void {
  const ts = new Date().toISOString().slice(11, 23);
  console.error(`[foreman ${ts}] ${msg}`);
}

/**
 * Build a default RunProgress object for a new Pi RPC run.
 */
function defaultProgress(phase: string): RunProgress {
  return {
    toolCalls: 0,
    toolBreakdown: {},
    filesChanged: [],
    turns: 0,
    costUsd: 0,
    tokensIn: 0,
    tokensOut: 0,
    lastToolCall: null,
    lastActivity: new Date().toISOString(),
    currentPhase: phase,
    costByPhase: {},
    agentByPhase: {},
  };
}

/**
 * PiRpcSpawnStrategy spawns `pi --mode rpc --no-session` as a child process
 * and communicates via JSONL over stdin/stdout using PiRpcClient.
 *
 * Falls back to DetachedSpawnStrategy on spawn failure to ensure zero regression.
 *
 * Implements the SpawnStrategy interface from dispatcher.ts.
 *
 * @param store - Optional ForemanStore for persisting run progress and status.
 *   When omitted (e.g. in unit tests), store operations are skipped.
 */
export class PiRpcSpawnStrategy implements SpawnStrategy {
  private readonly store: ForemanStore | null;

  constructor(store?: ForemanStore) {
    this.store = store ?? null;
  }

  async spawn(config: WorkerConfig): Promise<SpawnResult> {
    try {
      return await this.spawnPiRpc(config);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      log(`[PiRpcSpawnStrategy] Spawn failed (${message}); falling back to DetachedSpawnStrategy`);
      const fallback = new DetachedSpawnStrategy();
      return fallback.spawn(config);
    }
  }

  private async spawnPiRpc(config: WorkerConfig): Promise<SpawnResult> {
    const phase = "worker"; // Default phase for non-pipeline spawns
    const extensionsPath = resolveExtensionsPath();

    // Build child process env — strip CLAUDECODE to prevent nested session errors
    const childEnv: Record<string, string | undefined> = {
      ...process.env,
      CLAUDECODE: undefined,
      FOREMAN_PHASE: phase,
      FOREMAN_ALLOWED_TOOLS: (config.env.FOREMAN_ALLOWED_TOOLS ?? ""),
      FOREMAN_BASH_BLOCKLIST: (config.env.FOREMAN_BASH_BLOCKLIST ?? ""),
      FOREMAN_MAX_TURNS: (config.env.FOREMAN_MAX_TURNS ?? "80"),
      FOREMAN_MAX_TOKENS: (config.env.FOREMAN_MAX_TOKENS ?? "200000"),
      FOREMAN_RUN_ID: config.runId,
      FOREMAN_SEED_ID: config.seedId,
      PI_EXTENSIONS: extensionsPath,
    };

    // Also forward any env vars from config.env that aren't already set.
    // CLAUDECODE must remain stripped even if config.env contains it.
    for (const [key, value] of Object.entries(config.env)) {
      if (key === "CLAUDECODE") continue; // always strip
      if (!(key in childEnv) || childEnv[key] === undefined) {
        childEnv[key] = value;
      }
    }

    // Final strip: ensure CLAUDECODE is never passed to Pi process
    delete childEnv["CLAUDECODE"];

    const child = spawn("pi", ["--mode", "rpc", "--no-session"], {
      stdio: ["pipe", "pipe", "pipe"],
      cwd: config.worktreePath,
      env: childEnv as NodeJS.ProcessEnv,
    });

    const client = new PiRpcClient(child, { watchdogTimeoutMs: 60_000 });

    // Read TASK.md for context injection
    let taskMdContent = "";
    try {
      taskMdContent = await readFile(join(config.worktreePath, "TASK.md"), "utf-8");
    } catch {
      // Non-fatal: TASK.md may not exist in all scenarios
      log(`[PiRpcSpawnStrategy] Could not read TASK.md for ${config.seedId}`);
    }

    // Initialize RunProgress
    const progress = defaultProgress(phase);

    // Wire up event handlers BEFORE sending commands to avoid race conditions
    const resultPromise = this.wireEventHandlers(client, config, progress);

    // Send initialization sequence
    await client.sendCommand({ cmd: "set_model", model: config.model });

    if (taskMdContent) {
      await client.sendCommand({
        cmd: "set_context",
        files: [{ path: "/virtual/TASK.md", content: taskMdContent }],
      });
    }

    await client.sendCommand({ cmd: "prompt", text: config.prompt });

    // Wait for the agent to complete (resolves when agent_end is received
    // or rejects on unrecoverable error)
    await resultPromise;

    return {};
  }

  /**
   * Wire up all PiRpcClient event handlers.
   * Returns a promise that resolves when the agent completes (agent_end)
   * or rejects on unrecoverable error (budget exceeded, pipe break).
   */
  private wireEventHandlers(
    client: PiRpcClient,
    config: WorkerConfig,
    progress: RunProgress,
  ): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      let settled = false;
      let agentEndReceived = false;

      const settle = (fn: () => void): void => {
        if (settled) return;
        settled = true;
        fn();
      };

      // ── event dispatch ─────────────────────────────────────────────────
      client.on("event", (event: { type: string }) => {
        // ── agent_start — model mismatch detection ──────────────────────
        if (event.type === "agent_start") {
          const agentStart = event as PiAgentStartEvent;
          if (agentStart.model && agentStart.model !== config.model) {
            log(
              `[PiRpcSpawnStrategy] Pi model mismatch — Pi may not support requested model` +
              ` | requested=${config.model} actual=${agentStart.model}` +
              ` | seed=${config.seedId}`,
            );
          }
          return;
        }

        // ── agent_end ───────────────────────────────────────────────────
        if (event.type === "agent_end") {
          const agentEnd = event as PiAgentEndEvent;
          agentEndReceived = true;

          // AC-019-2: Store Pi session_id in runs.session_key
          if (agentEnd.sessionId) {
            this.store?.updateRun(config.runId, {
              session_key: `foreman:pi-rpc:${config.model}:${config.runId}:session-${agentEnd.sessionId}`,
            });
          }

          // Persist final progress and mark run complete
          this.store?.updateRunProgress(config.runId, progress);
          this.store?.updateRun(config.runId, {
            status: "completed",
            completed_at: new Date().toISOString(),
          });

          log(`[PiRpcSpawnStrategy] agent_end for ${config.seedId}: reason=${agentEnd.reason}`);
          client.destroy();
          settle(() => resolve());
          return;
        }

        // ── turn_end — accumulate cost ──────────────────────────────────
        if (event.type === "turn_end") {
          const turnEnd = event as PiTurnEndEvent;
          progress.turns += 1;
          progress.lastActivity = new Date().toISOString();

          if (turnEnd.inputTokens !== undefined) {
            progress.tokensIn += turnEnd.inputTokens;
          }
          if (turnEnd.outputTokens !== undefined) {
            progress.tokensOut += turnEnd.outputTokens;
          }

          // Persist progress after each turn
          this.store?.updateRunProgress(config.runId, progress);
          return;
        }

        // ── tool_execution_start ────────────────────────────────────────
        if (event.type === "tool_execution_start") {
          const toolStart = event as PiToolExecutionStartEvent;
          progress.toolCalls += 1;
          progress.lastToolCall = toolStart.toolName;
          progress.lastActivity = new Date().toISOString();
          progress.toolBreakdown[toolStart.toolName] =
            (progress.toolBreakdown[toolStart.toolName] ?? 0) + 1;
          this.store?.updateRunProgress(config.runId, progress);
          return;
        }

        // ── tool_execution_end ──────────────────────────────────────────
        if (event.type === "tool_execution_end") {
          const toolEnd = event as PiToolExecutionEndEvent;
          progress.lastActivity = new Date().toISOString();
          if (!toolEnd.success) {
            log(`[PiRpcSpawnStrategy] Tool ${toolEnd.toolName} failed for ${config.seedId}`);
          }
          this.store?.updateRunProgress(config.runId, progress);
          return;
        }

        // ── budget_exceeded ─────────────────────────────────────────────
        if (event.type === "budget_exceeded") {
          log(`[PiRpcSpawnStrategy] budget_exceeded for ${config.seedId}`);
          this.store?.updateRunProgress(config.runId, progress);
          this.store?.updateRun(config.runId, {
            status: "stuck",
            completed_at: new Date().toISOString(),
          });
          client.destroy();
          settle(() => reject(new Error("BUDGET_EXCEEDED")));
        }
      });

      // ── process error ──────────────────────────────────────────────────
      client.on("error", (err: Error) => {
        log(`[PiRpcSpawnStrategy] PiRpcClient error for ${config.seedId}: ${err.message}`);
        if (!agentEndReceived) {
          this.store?.updateRunProgress(config.runId, progress);
          this.store?.updateRun(config.runId, {
            status: "stuck",
            completed_at: new Date().toISOString(),
          });
          settle(() => reject(err));
        }
      });

      // ── process close (pipe break detection) ───────────────────────────
      client.on("close", () => {
        if (agentEndReceived) {
          // Normal close after agent_end — resolve if not already settled
          settle(() => resolve());
          return;
        }

        if (settled) return;

        // Wait up to PIPE_BREAK_WINDOW_MS before declaring a pipe break
        const timer = setTimeout(() => {
          if (!settled) {
            log(`[PiRpcSpawnStrategy] Pipe break detected for ${config.seedId} (no agent_end within ${PIPE_BREAK_WINDOW_MS}ms of close)`);
            this.store?.updateRunProgress(config.runId, progress);
            this.store?.updateRun(config.runId, {
              status: "stuck",
              completed_at: new Date().toISOString(),
            });
            settle(() => reject(new Error("Pi process closed without agent_end (pipe break)")));
          }
        }, PIPE_BREAK_WINDOW_MS);

        // Ensure the timer doesn't keep Node alive
        if (typeof (timer as NodeJS.Timeout).unref === "function") {
          (timer as NodeJS.Timeout).unref();
        }
      });
    });
  }
}
