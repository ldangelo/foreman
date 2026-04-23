/**
 * DaemonManager — manages ForemanDaemon lifecycle as a child process.
 *
 * Responsibilities:
 * - Spawn ForemanDaemon as a detached child process on `start()`
 * - Write PID to ~/.foreman/daemon.pid
 * - Detect already-running daemon (check PID + socket existence)
 * - Stop daemon on `stop()` (kill PID, clean up socket)
 * - Clean up stale socket on crash (detect stale socket before starting)
 * - Report status (running/not running/error)
 *
 * @module daemon-manager
 */

import { spawn } from "node:child_process";
import { join, dirname } from "node:path";
import { homedir } from "node:os";
import {
  existsSync,
  openSync,
  readFileSync,
  writeFileSync,
  unlinkSync,
  chmodSync,
  mkdirSync,
  closeSync,
} from "node:fs";

const DEFAULT_SOCKET_PATH = join(homedir(), ".foreman", "daemon.sock");
const DEFAULT_PID_PATH = join(homedir(), ".foreman", "daemon.pid");
const DAEMON_ENTRY = join(dirname(import.meta.filename), "..", "daemon", "index.js");

// ---------------------------------------------------------------------------
// Error types
// ---------------------------------------------------------------------------

export class DaemonAlreadyRunningError extends Error {
  readonly code = "DAEMON_ALREADY_RUNNING";
  constructor(public readonly pid: number) {
    super(`Daemon already running with PID ${pid}`);
    this.name = "DaemonAlreadyRunningError";
  }
}

export class DaemonNotRunningError extends Error {
  readonly code = "DAEMON_NOT_RUNNING";
  constructor() {
    super("Daemon is not running");
    this.name = "DaemonNotRunningError";
  }
}

export class DaemonStartError extends Error {
  readonly code = "DAEMON_START_ERROR";
  constructor(cause: unknown) {
    super(
      `Failed to start daemon: ${cause instanceof Error ? cause.message : String(cause)}`
    );
    this.name = "DaemonStartError";
    this.cause = cause;
  }
}

// ---------------------------------------------------------------------------
// DaemonManager
// ---------------------------------------------------------------------------

export interface DaemonStatus {
  running: boolean;
  pid: number | null;
  socketPath: string;
}

export class DaemonManager {
  private childProcess: ReturnType<typeof spawn> | null = null;

  constructor(options?: {
    socketPath?: string;
    pidPath?: string;
    stdoutPath?: string;
    stderrPath?: string;
  }) {
    this.__socketPath = options?.socketPath ?? DEFAULT_SOCKET_PATH;
    this.__pidPath = options?.pidPath ?? DEFAULT_PID_PATH;
    this.__stdoutPath = options?.stdoutPath ?? join(dirname(this.__pidPath), "daemon.out");
    this.__stderrPath = options?.stderrPath ?? join(dirname(this.__pidPath), "daemon.err");
  }

  /** Path to the PID file. */
  get pidPath(): string {
    return this.__pidPath;
  }
  private readonly __pidPath: string;

  /** Path to the Unix socket (alias for socketPath getter). */
  get socketPath(): string {
    return this.__socketPath;
  }
  private readonly __socketPath: string;

  /** Path to the daemon stdout log. */
  get stdoutPath(): string {
    return this.__stdoutPath;
  }
  private readonly __stdoutPath: string;

  /** Path to the daemon stderr log. */
  get stderrPath(): string {
    return this.__stderrPath;
  }
  private readonly __stderrPath: string;

  /** Check if a daemon is currently running (PID exists + socket exists). */
  isRunning(): boolean {
    const pid = this.#readPid();
    if (pid === null) return false;
    if (!existsSync(this.socketPath)) {
      try {
        process.kill(pid, 0);
        return false;
      } catch {
        this.#removePidFile();
        return false;
      }
    }
    try {
      // Signal 0 checks if the process exists without sending a signal.
      process.kill(pid, 0);
      return true;
    } catch {
      // Process does not exist — clean up stale PID file.
      this.#removePidFile();
      return false;
    }
  }

  /** Get daemon status. */
  status(): DaemonStatus {
    const pid = this.#readPid();
    const running = this.isRunning();
    return {
      running,
      pid: running ? pid : null,
      socketPath: this.socketPath,
    };
  }

  /** Start the daemon as a detached child process.
   *
   * @throws DaemonAlreadyRunningError if a daemon is already running.
   * @throws DaemonStartError if the child process fails to spawn.
   */
  start(): void {
    if (this.isRunning()) {
      const pid = this.#readPid()!;
      throw new DaemonAlreadyRunningError(pid);
    }

    // Ensure .foreman directory exists with correct permissions.
    mkdirSync(dirname(this.socketPath), { recursive: true });
    mkdirSync(dirname(this.pidPath), { recursive: true });

    // Remove stale socket if present (crash cleanup).
    if (existsSync(this.socketPath)) {
      try {
        unlinkSync(this.socketPath);
      } catch {
        // ignore
      }
    }

    try {
      const stdoutFd = openSync(this.stdoutPath, "a");
      const stderrFd = openSync(this.stderrPath, "a");
      this.childProcess = spawn(process.execPath, [DAEMON_ENTRY], {
        detached: true,
        stdio: ["ignore", stdoutFd, stderrFd],
        env: { ...process.env },
      });
      closeSync(stdoutFd);
      closeSync(stderrFd);

      this.childProcess.on("error", (err) => {
        // Child failed to start — clean up PID file.
        this.#removePidFile();
        throw new DaemonStartError(err);
      });

      // Unref so the parent doesn't wait for the child.
      this.childProcess.unref();

      // Write PID after spawn (child PID is set by spawn()).
      const pid = this.childProcess.pid!;
      writeFileSync(this.pidPath, String(pid), "utf-8");
      chmodSync(this.pidPath, 0o600);

      // Child is now running independently.
      this.childProcess = null;
    } catch (err: unknown) {
      this.#removePidFile();
      throw new DaemonStartError(err);
    }
  }

  /** Stop the daemon (kill PID + remove socket).
   *
   * @throws DaemonNotRunningError if no daemon is running.
   */
  stop(): void {
    if (!this.isRunning()) {
      throw new DaemonNotRunningError();
    }

    const pid = this.#readPid()!;

    try {
      process.kill(pid, "SIGTERM");
    } catch {
      // Process may have already exited — clean up anyway.
    }

    // Clean up PID file.
    this.#removePidFile();

    // Clean up socket.
    if (existsSync(this.socketPath)) {
      try {
        unlinkSync(this.socketPath);
      } catch {
        // ignore
      }
    }
  }

  // -------------------------------------------------------------------------
  // Private helpers
  // -------------------------------------------------------------------------

  /** Read PID from the PID file. Returns null if not present or invalid. */
  #readPid(): number | null {
    if (!existsSync(this.pidPath)) return null;
    try {
      const content = readFileSync(this.pidPath, "utf-8").trim();
      const pid = parseInt(content, 10);
      return isNaN(pid) ? null : pid;
    } catch {
      return null;
    }
  }

  /** Remove the PID file, ignoring errors. */
  #removePidFile(): void {
    try {
      if (existsSync(this.pidPath)) unlinkSync(this.pidPath);
    } catch {
      // ignore
    }
  }
}
