import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const TMUX_TIMEOUT = 5000;

// ── Type Definitions ─────────────────────────────────────────────────────

/** Options for creating a new tmux session */
export interface TmuxSpawnOptions {
  sessionName: string;
  command: string;
  cwd: string;
  env?: Record<string, string>;
}

/** Result of creating a tmux session */
export interface TmuxCreateResult {
  sessionName: string;
  created: boolean;
}

/** Information about an active tmux session */
export interface TmuxSessionInfo {
  sessionName: string;
  created: string;
  attached: boolean;
  windowCount: number;
}

// ── Standalone Functions ─────────────────────────────────────────────────

/**
 * Generate a tmux session name from a seed ID.
 * Format: `foreman-<seedId>` with invalid characters replaced by hyphens.
 */
export function tmuxSessionName(seedId: string): string {
  const sanitized = seedId.replace(/[:.\s]/g, "-").trim();
  if (!sanitized || sanitized.replace(/-/g, "").length === 0) {
    return "foreman-unknown";
  }
  return `foreman-${sanitized}`;
}

// ── TmuxClient Class ─────────────────────────────────────────────────────

export class TmuxClient {
  private availableCache: boolean | null = null;

  /**
   * Check if tmux is available on this system.
   * Result is cached for the lifetime of this instance.
   * Returns false when FOREMAN_TMUX_DISABLED=true.
   */
  async isAvailable(): Promise<boolean> {
    if (process.env.FOREMAN_TMUX_DISABLED === "true") {
      return false;
    }

    if (this.availableCache !== null) {
      return this.availableCache;
    }

    try {
      await execFileAsync("which", ["tmux"], { timeout: TMUX_TIMEOUT });
      this.availableCache = true;
    } catch {
      this.availableCache = false;
    }

    return this.availableCache;
  }

  /**
   * Create a new detached tmux session.
   * Returns { created: false } on failure with a warning logged to stderr (TMUX-002).
   */
  async createSession(opts: TmuxSpawnOptions): Promise<TmuxCreateResult> {
    const { sessionName, command, cwd, env } = opts;

    try {
      const execOpts: { timeout: number; cwd: string; env?: NodeJS.ProcessEnv } = {
        timeout: TMUX_TIMEOUT,
        cwd,
      };
      if (env) {
        execOpts.env = { ...process.env, ...env };
      }

      await execFileAsync(
        "tmux",
        ["new-session", "-d", "-s", sessionName, "-c", cwd, command],
        execOpts,
      );
      return { sessionName, created: true };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      process.stderr.write(
        `[foreman] TMUX-002: tmux session creation failed for ${sessionName}: ${message}\n`,
      );
      return { sessionName, created: false };
    }
  }

  /**
   * Kill a tmux session by name.
   * Returns true if killed, false if session didn't exist (TMUX-005).
   */
  async killSession(sessionName: string): Promise<boolean> {
    try {
      await execFileAsync("tmux", ["kill-session", "-t", sessionName], {
        timeout: TMUX_TIMEOUT,
      });
      return true;
    } catch {
      return false;
    }
  }

  /**
   * Check if a tmux session exists.
   * Returns true if exit code 0, false otherwise.
   */
  async hasSession(sessionName: string): Promise<boolean> {
    try {
      await execFileAsync("tmux", ["has-session", "-t", sessionName], {
        timeout: TMUX_TIMEOUT,
      });
      return true;
    } catch {
      return false;
    }
  }

  /**
   * Capture the current pane output of a tmux session.
   * Returns stdout split into lines, or empty array if session doesn't exist (TMUX-004).
   */
  async capturePaneOutput(sessionName: string): Promise<string[]> {
    try {
      const { stdout } = await execFileAsync(
        "tmux",
        ["capture-pane", "-t", sessionName, "-p"],
        { timeout: TMUX_TIMEOUT },
      );
      if (!stdout.trim()) {
        return [];
      }
      return stdout.trimEnd().split("\n");
    } catch {
      return [];
    }
  }

  /**
   * List all foreman-* tmux sessions.
   * Returns empty array if tmux is unavailable or no sessions exist.
   */
  async listForemanSessions(): Promise<TmuxSessionInfo[]> {
    try {
      const { stdout } = await execFileAsync(
        "tmux",
        [
          "list-sessions",
          "-F",
          "#{session_name} #{session_created} #{session_attached} #{session_windows}",
        ],
        { timeout: TMUX_TIMEOUT },
      );

      if (!stdout.trim()) {
        return [];
      }

      const lines = stdout.trim().split("\n");
      const sessions: TmuxSessionInfo[] = [];

      for (const line of lines) {
        const parts = line.split(" ");
        if (parts.length < 4) continue;

        const sessionName = parts[0];
        if (!sessionName.startsWith("foreman-")) continue;

        sessions.push({
          sessionName,
          created: parts[1],
          attached: parts[2] === "1",
          windowCount: parseInt(parts[3], 10),
        });
      }

      return sessions;
    } catch {
      return [];
    }
  }

  /**
   * Get the tmux version string.
   * Returns null if tmux is unavailable or output format is unexpected.
   */
  async getTmuxVersion(): Promise<string | null> {
    try {
      const { stdout } = await execFileAsync("tmux", ["-V"], {
        timeout: TMUX_TIMEOUT,
      });

      const match = stdout.trim().match(/^tmux\s+(\S+)$/);
      if (!match) {
        return null;
      }
      return match[1];
    } catch {
      return null;
    }
  }
}
