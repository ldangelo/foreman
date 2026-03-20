import { EventEmitter } from "node:events";
import { createInterface } from "node:readline";
import type { ChildProcess } from "node:child_process";

// ── Pi RPC command types (sent to Pi via stdin) ───────────────────────────────

export interface PiPromptCommand {
  cmd: "prompt";
  text: string;
}

export interface PiSetModelCommand {
  cmd: "set_model";
  model: string;
}

export interface PiSetContextCommand {
  cmd: "set_context";
  files: Array<{ path: string; content: string }>;
}

export interface PiSwitchSessionCommand {
  cmd: "switch_session";
  sessionId: string;
}

export interface PiForkCommand {
  cmd: "fork";
  label?: string;
}

export interface PiHealthCheckCommand {
  type: "health_check";
}

export type PiCommand =
  | PiPromptCommand
  | PiSetModelCommand
  | PiSetContextCommand
  | PiSwitchSessionCommand
  | PiForkCommand
  | PiHealthCheckCommand;

// ── Pi RPC event types (received from Pi via stdout) ─────────────────────────

export interface PiAgentStartEvent {
  type: "agent_start";
  sessionId?: string;
  /** Model identifier reported by Pi — used for mismatch detection */
  model?: string;
}

export interface PiAgentEndEvent {
  type: "agent_end";
  reason: string;
  error?: string;
  sessionId?: string;
}

export interface PiTurnStartEvent {
  type: "turn_start";
  turnNumber: number;
}

export interface PiTurnEndEvent {
  type: "turn_end";
  turnNumber: number;
  totalTokens?: number;
  inputTokens?: number;
  outputTokens?: number;
}

export interface PiToolExecutionStartEvent {
  type: "tool_execution_start";
  toolName: string;
  toolCallId: string;
}

export interface PiToolExecutionEndEvent {
  type: "tool_execution_end";
  toolName: string;
  toolCallId: string;
  durationMs?: number;
  success: boolean;
}

export interface PiBudgetExceededEvent {
  type: "budget_exceeded";
  reason: string;
}

export interface PiExtensionUiEvent {
  type: "extension_ui_request";
  extensionName: string;
  data: unknown;
}

export interface PiErrorEvent {
  type: "error";
  message: string;
}

export interface PiHealthCheckResponseEvent {
  type: "health_check_response";
  /** Extension names that successfully loaded, e.g. ["foreman-tool-gate", "foreman-budget", "foreman-audit"] */
  loadedExtensions: string[];
  status: "ok" | "error";
}

export type PiEvent =
  | PiAgentStartEvent
  | PiAgentEndEvent
  | PiTurnStartEvent
  | PiTurnEndEvent
  | PiToolExecutionStartEvent
  | PiToolExecutionEndEvent
  | PiBudgetExceededEvent
  | PiExtensionUiEvent
  | PiErrorEvent
  | PiHealthCheckResponseEvent;

// ── Client options ────────────────────────────────────────────────────────────

export interface PiRpcClientOptions {
  /** How long to wait without stdout activity before emitting an error. Default: 60_000 ms. */
  watchdogTimeoutMs?: number;
}

// ── PiRpcClient ───────────────────────────────────────────────────────────────

/**
 * JSONL-over-stdin/stdout client for communicating with a Pi RPC process.
 *
 * Events emitted:
 * - `'event'` (event: PiEvent)  — a parsed Pi event received from stdout
 * - `'error'` (err: Error)      — pipe error or watchdog timeout
 * - `'close'` ()                — process stdout has closed
 */
export class PiRpcClient extends EventEmitter {
  private readonly process: ChildProcess;
  private watchdogTimer: ReturnType<typeof setTimeout> | null = null;
  private readonly watchdogTimeoutMs: number;

  constructor(childProcess: ChildProcess, options: PiRpcClientOptions = {}) {
    super();
    this.process = childProcess;
    this.watchdogTimeoutMs = options.watchdogTimeoutMs ?? 60_000;

    this.setupStdout();
    this.setupStderr();
    this.resetWatchdog();
  }

  // ── Private setup ───────────────────────────────────────────────────────────

  private setupStdout(): void {
    if (!this.process.stdout) {
      throw new Error(
        "PiRpcClient requires a child process with stdout pipe"
      );
    }

    const rl = createInterface({
      input: this.process.stdout,
      crlfDelay: Infinity,
    });

    rl.on("line", (line: string) => {
      // Any stdout activity resets the watchdog
      this.resetWatchdog();

      const trimmed = line.trim();
      if (!trimmed) return;

      let parsed: unknown;
      try {
        parsed = JSON.parse(trimmed);
      } catch {
        // Ignore non-JSON lines (e.g., Pi startup banners, log lines)
        return;
      }

      this.emit("event", parsed as PiEvent);
    });

    rl.on("close", () => {
      this.clearWatchdog();
      this.emit("close");
    });
  }

  private setupStderr(): void {
    // Absorb stderr — Pi may write diagnostic messages there.
    this.process.stderr?.on("data", () => {
      // intentionally empty
    });
  }

  // ── Watchdog ────────────────────────────────────────────────────────────────

  private resetWatchdog(): void {
    this.clearWatchdog();
    this.watchdogTimer = setTimeout(() => {
      this.emit(
        "error",
        new Error(
          `PiRpcClient: no stdout activity for ${this.watchdogTimeoutMs}ms (watchdog timeout)`
        )
      );
    }, this.watchdogTimeoutMs);
  }

  private clearWatchdog(): void {
    if (this.watchdogTimer !== null) {
      clearTimeout(this.watchdogTimer);
      this.watchdogTimer = null;
    }
  }

  // ── Public API ──────────────────────────────────────────────────────────────

  /**
   * Send a command to Pi via stdin as a JSONL line.
   *
   * Handles backpressure: if `stdin.write()` returns `false` (the kernel
   * buffer is full), the returned promise resolves only after the `'drain'`
   * event fires, preventing unbounded memory growth.
   */
  async sendCommand(command: PiCommand): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const stdin = this.process.stdin;

      if (!stdin) {
        reject(new Error("PiRpcClient: child process stdin is not available"));
        return;
      }

      const line = JSON.stringify(command) + "\n";
      const canContinue = stdin.write(line);

      if (canContinue) {
        resolve();
      } else {
        // Backpressure: wait for drain before signalling the caller
        const onDrain = (): void => {
          stdin.removeListener("error", onError);
          resolve();
        };
        const onError = (err: Error): void => {
          stdin.removeListener("drain", onDrain);
          reject(err);
        };
        stdin.once("drain", onDrain);
        stdin.once("error", onError);
      }
    });
  }

  /**
   * Tear down the client: cancel the watchdog timer and close stdin,
   * which signals Pi to shut down cleanly.
   */
  destroy(): void {
    this.clearWatchdog();
    try {
      this.process.stdin?.end();
    } catch {
      // Ignore if stdin is already closed or destroyed
    }
  }
}
