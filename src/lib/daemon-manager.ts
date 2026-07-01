import { join, dirname } from "node:path";
import { homedir } from "node:os";
import { existsSync, readFileSync, unlinkSync } from "node:fs";

const DEFAULT_SOCKET_PATH = join(homedir(), ".foreman", "daemon.sock");
const DEFAULT_PID_PATH = join(homedir(), ".foreman", "daemon.pid");

export class DaemonNotRunningError extends Error {
  readonly code = "DAEMON_NOT_RUNNING";
  constructor() {
    super("Daemon is not running");
    this.name = "DaemonNotRunningError";
  }
}

export interface DaemonStatus {
  running: boolean;
  pid: number | null;
  socketPath: string;
}

/** Inspect or stop stray legacy daemon processes after Elixir cutover. */
export class DaemonManager {
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

  get pidPath(): string {
    return this.__pidPath;
  }
  private readonly __pidPath: string;

  get socketPath(): string {
    return this.__socketPath;
  }
  private readonly __socketPath: string;

  get stdoutPath(): string {
    return this.__stdoutPath;
  }
  private readonly __stdoutPath: string;

  get stderrPath(): string {
    return this.__stderrPath;
  }
  private readonly __stderrPath: string;

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
      process.kill(pid, 0);
      return true;
    } catch {
      this.#removePidFile();
      return false;
    }
  }

  status(): DaemonStatus {
    const pid = this.#readPid();
    const running = this.isRunning();
    return {
      running,
      pid: running ? pid : null,
      socketPath: this.socketPath,
    };
  }

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
    this.#removePidFile();
    if (existsSync(this.socketPath)) {
      try {
        unlinkSync(this.socketPath);
      } catch {
        // ignore
      }
    }
  }

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

  #removePidFile(): void {
    try {
      if (existsSync(this.pidPath)) unlinkSync(this.pidPath);
    } catch {
      // ignore
    }
  }
}
