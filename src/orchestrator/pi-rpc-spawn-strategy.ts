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
  PiHealthCheckResponseEvent,
} from "./pi-rpc-client.js";
import { DetachedSpawnStrategy } from "./dispatcher.js";
import type { SpawnStrategy, SpawnResult, WorkerConfig } from "./dispatcher.js";
import type { ForemanStore, RunProgress } from "../lib/store.js";

// ── Pi Binary Detection ──────────────────────────────────────────────────

/** Valid values for the FOREMAN_SPAWN_STRATEGY environment variable. */
export type SpawnStrategyOverride = "pi-rpc" | "tmux" | "detached";

/**
 * Valid values for the FOREMAN_PI_SESSION_STRATEGY environment variable.
 *
 *   reuse   (default): Start a fresh Pi process per pipeline phase.
 *                      Sends set_model + set_context + prompt. No prior-session
 *                      commands are sent.
 *   resume:            Start a new Pi process and resume a prior session via
 *                      a switch_session command sent before the prompt.
 *                      Falls back to reuse behavior when no prior session exists.
 *   fork:              Fork from an existing Pi session before the prompt,
 *                      creating a branched session.
 *                      Falls back to reuse behavior when no prior session exists.
 */
export type PiSessionStrategy = "reuse" | "resume" | "fork";

/**
 * Extract the Pi session ID from a Foreman session key.
 *
 * Session keys are stored in the format:
 *   foreman:pi-rpc:<model>:<runId>:session-<sessionId>
 *
 * @param sessionKey - Value from runs.session_key, or null.
 * @returns The extracted sessionId string, or null when the key is absent
 *          or does not contain a valid session- suffix.
 */
export function extractPiSessionId(sessionKey: string | null): string | null {
  if (!sessionKey) return null;
  const match = sessionKey.match(/session-([^:]+)$/);
  if (!match || !match[1]) return null;
  return match[1];
}

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

/** Timeout to wait for a resumed Pi process to send agent_start before giving up (ms). */
const CRASH_RESUME_TIMEOUT_MS = 5_000;

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
function defaultProgress(phase: string, maxTurns: number, maxTokens: number): RunProgress {
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
    maxTurns,
    maxTokens,
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

    // Parse turn / token budgets from env for progress tracking
    const maxTurns = parseInt(childEnv.FOREMAN_MAX_TURNS ?? "80", 10);
    const maxTokens = parseInt(childEnv.FOREMAN_MAX_TOKENS ?? "200000", 10);

    // Initialize RunProgress
    const progress = defaultProgress(phase, maxTurns, maxTokens);

    // Shared flag: set to true when agent_end is received (used by both
    // wireEventHandlers and the crash handler to distinguish normal vs crash exit).
    let agentEndReceived = false;

    // Wire up event handlers BEFORE sending commands to avoid race conditions
    const resultPromise = this.wireEventHandlers(client, config, progress, (received) => {
      agentEndReceived = received;
    });
    // Attach a no-op catch so that if we abandon resultPromise early (e.g. due
    // to health check failure), Node doesn't report an unhandled rejection.
    resultPromise.catch(() => undefined);

    // ── Crash detection: listen for unexpected process exit ────────────
    child.on("exit", (exitCode, signal) => {
      if (!agentEndReceived) {
        void this.handleCrash(exitCode, signal, config, childEnv as NodeJS.ProcessEnv, progress);
      }
    });

    // Send initialization sequence
    await client.sendCommand({ cmd: "set_model", model: config.model });

    if (taskMdContent) {
      await client.sendCommand({
        cmd: "set_context",
        files: [{ path: "/virtual/TASK.md", content: taskMdContent }],
      });
    }

    // ── Extension health check — verify foreman-tool-gate loaded ─────
    // Throws if foreman-tool-gate is absent or Pi doesn't respond within 5s.
    // On throw: spawnPiRpc rejects, outer spawn() falls back to DetachedSpawnStrategy.
    await this.performHealthCheck(client, config.seedId);

    // ── Session lifecycle: resume / fork / reuse ───────────────────────
    await this.applySessionStrategy(client, config);

    await client.sendCommand({ cmd: "prompt", text: config.prompt });

    // Wait for the agent to complete (resolves when agent_end is received
    // or rejects on unrecoverable error)
    await resultPromise;

    return {};
  }

  /**
   * Handle an unexpected Pi process crash (exit without a preceding agent_end).
   *
   * Attempts session resume:
   *   1. Read runs.session_key from the store for the current run.
   *   2. If a session key exists: spawn a new Pi process and send switch_session.
   *   3. If the resumed Pi process fails to send agent_start within 5 seconds,
   *      fall back to DetachedSpawnStrategy for the run.
   *
   * If no session key is available, falls through without action — the existing
   * pipe-break detection in wireEventHandlers will handle the stuck state.
   *
   * @param exitCode - Process exit code, or null if killed by a signal.
   * @param signal   - Signal name if killed, or null.
   * @param config   - Worker configuration for the run.
   * @param childEnv - Child process environment to reuse for the resumed process.
   * @param progress - Current RunProgress to persist on crash.
   */
  private async handleCrash(
    exitCode: number | null,
    signal: string | null,
    config: WorkerConfig,
    childEnv: NodeJS.ProcessEnv,
    progress: RunProgress,
  ): Promise<void> {
    log(
      `[PiRpcSpawnStrategy] Pi process crashed for ${config.seedId}` +
      ` (exitCode=${exitCode ?? "null"} signal=${signal ?? "null"})`,
    );

    // Look up stored session key for this run
    const run = this.store?.getRun(config.runId) ?? null;
    const sessionId = extractPiSessionId(run?.session_key ?? null);

    if (!sessionId) {
      log(
        `[PiRpcSpawnStrategy] Crash recovery: no session key for run ${config.runId}; ` +
        `skipping resume (pipe-break detection will handle stuck state)`,
      );
      return;
    }

    log(
      `[PiRpcSpawnStrategy] Crash recovery: attempting session resume ` +
      `sessionId=${sessionId} for run ${config.runId}`,
    );

    try {
      // Spawn a new Pi process for the resume attempt
      const resumedChild = spawn("pi", ["--mode", "rpc", "--no-session"], {
        stdio: ["pipe", "pipe", "pipe"],
        cwd: config.worktreePath,
        env: childEnv,
      });

      const resumedClient = new PiRpcClient(resumedChild, { watchdogTimeoutMs: 60_000 });

      // Wait for agent_start within CRASH_RESUME_TIMEOUT_MS to confirm the
      // session resumed successfully.
      const resumeOk = await new Promise<boolean>((resolve) => {
        let settled = false;

        const timeout = setTimeout(() => {
          if (settled) return;
          settled = true;
          resumedClient.removeListener("event", onEvent);
          resumedClient.removeListener("error", onError);
          resolve(false);
        }, CRASH_RESUME_TIMEOUT_MS);

        const onEvent = (event: { type: string }): void => {
          if (event.type !== "agent_start") return;
          if (settled) return;
          settled = true;
          clearTimeout(timeout);
          resumedClient.removeListener("event", onEvent);
          resumedClient.removeListener("error", onError);
          resolve(true);
        };

        const onError = (): void => {
          if (settled) return;
          settled = true;
          clearTimeout(timeout);
          resumedClient.removeListener("event", onEvent);
          resolve(false);
        };

        resumedClient.on("event", onEvent);
        resumedClient.on("error", onError);

        // Send switch_session to resume prior session
        resumedClient.sendCommand({ cmd: "switch_session", sessionId }).catch(() => {
          if (!settled) {
            settled = true;
            clearTimeout(timeout);
            resumedClient.removeListener("event", onEvent);
            resumedClient.removeListener("error", onError);
            resolve(false);
          }
        });
      });

      if (!resumeOk) {
        log(
          `[PiRpcSpawnStrategy] Crash recovery: resume failed for run ${config.runId}` +
          ` (no agent_start within ${CRASH_RESUME_TIMEOUT_MS}ms); falling back to DetachedSpawnStrategy`,
        );
        resumedClient.destroy();
        this.store?.updateRunProgress(config.runId, progress);
        // Fall back to DetachedSpawnStrategy
        const fallback = new DetachedSpawnStrategy();
        await fallback.spawn(config);
        return;
      }

      log(
        `[PiRpcSpawnStrategy] Crash recovery: session resumed successfully ` +
        `sessionId=${sessionId} for run ${config.runId}`,
      );

      // Wire up remaining event handlers for the resumed session
      this.wireEventHandlers(resumedClient, config, progress, () => undefined).catch(() => undefined);

    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      log(
        `[PiRpcSpawnStrategy] Crash recovery: exception during resume for run ${config.runId}: ${message}` +
        `; falling back to DetachedSpawnStrategy`,
      );
      this.store?.updateRunProgress(config.runId, progress);
      try {
        const fallback = new DetachedSpawnStrategy();
        await fallback.spawn(config);
      } catch {
        // Fallback failure is non-fatal at this point — the run will be stuck
      }
    }
  }

  /**
   * Apply the FOREMAN_PI_SESSION_STRATEGY before sending the prompt command.
   *
   * Strategy behaviour:
   *   reuse  (default) — no-op; let Pi start a fresh session.
   *   resume           — send switch_session with the prior Pi session ID.
   *   fork             — send fork to branch the prior Pi session.
   *
   * Both resume and fork fall back silently to reuse behaviour when no prior
   * session key can be found in the store.
   */
  private async applySessionStrategy(
    client: PiRpcClient,
    config: WorkerConfig,
  ): Promise<void> {
    const raw = process.env.FOREMAN_PI_SESSION_STRATEGY;
    const strategy: PiSessionStrategy =
      raw === "resume" || raw === "fork" ? raw : "reuse";

    if (strategy === "reuse") {
      return; // Default behaviour — nothing extra to send
    }

    // Look up the prior session key from the store
    const run = this.store?.getRun(config.runId) ?? null;
    const sessionId = extractPiSessionId(run?.session_key ?? null);

    if (!sessionId) {
      // No prior session found — fall back to reuse behaviour
      log(
        `[PiRpcSpawnStrategy] ${strategy} strategy: no prior session for run ${config.runId}; falling back to reuse`,
      );
      return;
    }

    if (strategy === "resume") {
      log(
        `[PiRpcSpawnStrategy] resume strategy: sending switch_session sessionId=${sessionId} for run ${config.runId}`,
      );
      await client.sendCommand({ cmd: "switch_session", sessionId });
    } else if (strategy === "fork") {
      log(
        `[PiRpcSpawnStrategy] fork strategy: sending fork for run ${config.runId} (prior sessionId=${sessionId})`,
      );
      await client.sendCommand({ cmd: "fork" });
    }
  }

  /**
   * Send a health_check command to Pi and wait for the response.
   * Verifies that the `foreman-tool-gate` extension loaded successfully.
   *
   * If Pi does not respond within 5 seconds, or if `foreman-tool-gate` is
   * absent from the loaded extensions list, this method throws an Error which
   * causes spawnPiRpc() to reject, triggering fallback to DetachedSpawnStrategy.
   *
   * @param client - The PiRpcClient instance connected to the Pi process.
   * @param seedId - The seed ID, used for logging only.
   */
  private performHealthCheck(client: PiRpcClient, seedId: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      let settled = false;

      const timeout = setTimeout(() => {
        if (settled) return;
        settled = true;
        client.removeListener("event", onEvent);
        reject(new Error("Extension health check timed out after 5s"));
      }, 5_000);

      const onEvent = (event: { type: string }): void => {
        if (event.type !== "health_check_response") {
          // Not the response we are waiting for — keep listening
          return;
        }

        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        client.removeListener("event", onEvent);

        const hcEvent = event as PiHealthCheckResponseEvent;
        const loadedExtensions = hcEvent.loadedExtensions ?? [];

        if (!loadedExtensions.includes("foreman-tool-gate")) {
          const err = new Error(
            `foreman-tool-gate extension not loaded. Loaded: [${loadedExtensions.join(", ")}]. ` +
            `Check PI_EXTENSIONS env var and ensure packages/foreman-pi-extensions/dist/index.js exists.`,
          );
          log(`[PiRpcSpawnStrategy] Extension health check failed for ${seedId}: ${err.message}`);
          reject(err);
          return;
        }

        log(`[PiRpcSpawnStrategy] Extension health check passed for ${seedId}: extensions=[${loadedExtensions.join(", ")}]`);
        resolve();
      };

      client.on("event", onEvent);
      void client.sendCommand({ type: "health_check" });
    });
  }

  /**
   * Wire up all PiRpcClient event handlers.
   * Returns a promise that resolves when the agent completes (agent_end)
   * or rejects on unrecoverable error (budget exceeded, pipe break).
   *
   * @param agentEndCallback - Optional callback invoked with `true` when agent_end
   *   is received. Used by the crash handler to distinguish normal vs crash exit.
   */
  private wireEventHandlers(
    client: PiRpcClient,
    config: WorkerConfig,
    progress: RunProgress,
    agentEndCallback?: (received: boolean) => void,
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
        // ── agent_start — model capture and mismatch detection ─────────
        if (event.type === "agent_start") {
          const agentStart = event as PiAgentStartEvent;
          if (agentStart.model) {
            // Record the actual model Pi is using in progress
            progress.model = agentStart.model;
            this.store?.updateRunProgress(config.runId, progress);
            if (agentStart.model !== config.model) {
              log(
                `[PiRpcSpawnStrategy] Pi model mismatch — Pi may not support requested model` +
                ` | requested=${config.model} actual=${agentStart.model}` +
                ` | seed=${config.seedId}`,
              );
            }
          }
          return;
        }

        // ── agent_end ───────────────────────────────────────────────────
        if (event.type === "agent_end") {
          const agentEnd = event as PiAgentEndEvent;
          agentEndReceived = true;
          agentEndCallback?.(true);

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
