/**
 * AgentMailClient — HTTP client for the Agent Mail service (port 8765 FastMCP).
 *
 * TRD-020: Agent Mail HTTP Client
 *
 * Design principles:
 *   - Fire-and-forget with AbortController timeout (default 500ms)
 *   - Silent failure: ALL errors (network, timeout, non-2xx) are caught and swallowed
 *   - fetchInbox() returns [] on any failure
 *   - healthCheck() returns false on any failure
 *   - Base URL resolved from: constructor config → AGENT_MAIL_URL env var → default
 *
 * The client is designed to be resilient when Agent Mail is not running.
 * Callers should never need to wrap calls in try/catch.
 */

import { readFileSync } from "node:fs";
import { join } from "node:path";

// ── Types ─────────────────────────────────────────────────────────────────────

export interface AgentMailMessage {
  id: string;
  from: string;
  to: string;
  subject: string;
  body: string;
  metadata?: Record<string, unknown>;
  receivedAt: string;
  acknowledged: boolean;
}

export interface ReservationResult {
  success: boolean;
  conflicts?: Array<{ path: string; heldBy: string; expiresAt: string }>;
}

/** Optional constructor config — all fields optional. */
export interface AgentMailClientConfig {
  /** Base URL of the Agent Mail service. Defaults to AGENT_MAIL_URL env var or http://localhost:8765. */
  baseUrl?: string;
  /** Timeout in ms for all requests. Defaults to 500. */
  timeoutMs?: number;
}

/** Shape of the optional .foreman/agent-mail.json config file. */
interface AgentMailFileConfig {
  baseUrl?: string;
  timeoutMs?: number;
  enabled?: boolean;
}

// ── Default config file content (written by init command) ─────────────────────

export const DEFAULT_AGENT_MAIL_CONFIG: AgentMailFileConfig = {
  baseUrl: "http://localhost:8765",
  timeoutMs: 500,
  enabled: true,
};

// ── Helpers ───────────────────────────────────────────────────────────────────

const DEFAULT_BASE_URL = "http://localhost:8765";
const DEFAULT_TIMEOUT_MS = 500;

/**
 * Attempt to read the optional .foreman/agent-mail.json config file.
 * Returns undefined if the file does not exist or cannot be parsed.
 */
function loadFileConfig(): AgentMailFileConfig | undefined {
  try {
    const configPath = join(process.cwd(), ".foreman", "agent-mail.json");
    const raw = readFileSync(configPath, "utf-8");
    return JSON.parse(raw) as AgentMailFileConfig;
  } catch {
    // File not found or parse error — ignore
    return undefined;
  }
}

/**
 * Resolve the base URL from: constructor config → env var → file config → default.
 */
function resolveBaseUrl(configBaseUrl: string | undefined): string {
  if (configBaseUrl !== undefined && configBaseUrl !== "") {
    return configBaseUrl.replace(/\/$/, "");
  }
  const envUrl = process.env.AGENT_MAIL_URL;
  if (envUrl !== undefined && envUrl !== "") {
    return envUrl.replace(/\/$/, "");
  }
  const fileConfig = loadFileConfig();
  if (fileConfig?.baseUrl !== undefined && fileConfig.baseUrl !== "") {
    return fileConfig.baseUrl.replace(/\/$/, "");
  }
  return DEFAULT_BASE_URL;
}

/**
 * Resolve the timeout from: constructor config → file config → default.
 */
function resolveTimeoutMs(configTimeoutMs: number | undefined): number {
  if (configTimeoutMs !== undefined) {
    return configTimeoutMs;
  }
  const fileConfig = loadFileConfig();
  if (fileConfig?.timeoutMs !== undefined) {
    return fileConfig.timeoutMs;
  }
  return DEFAULT_TIMEOUT_MS;
}

// ── AgentMailClient ────────────────────────────────────────────────────────────

export class AgentMailClient {
  private readonly baseUrl: string;
  private readonly timeoutMs: number;

  constructor(config?: AgentMailClientConfig) {
    this.baseUrl = resolveBaseUrl(config?.baseUrl);
    this.timeoutMs = resolveTimeoutMs(config?.timeoutMs);
  }

  // ── Internal fetch helper ─────────────────────────────────────────────────

  /**
   * Perform a fetch with an AbortController-based timeout.
   * Throws on network error, timeout, or non-2xx — callers are responsible for catching.
   */
  private async fetchWithTimeout(
    url: string,
    init?: RequestInit,
  ): Promise<Response> {
    const controller = new AbortController();
    const timerId = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const response = await fetch(url, { ...init, signal: controller.signal });
      return response;
    } finally {
      clearTimeout(timerId);
    }
  }

  /** Build a POST request init object with JSON body. */
  private postJson(body: unknown): RequestInit {
    return {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    };
  }

  // ── Public API ────────────────────────────────────────────────────────────

  /**
   * Register an agent with the mail service.
   * Sends POST /register_agent { name }.
   * Silently ignores all errors.
   */
  async registerAgent(name: string): Promise<void> {
    try {
      await this.fetchWithTimeout(
        `${this.baseUrl}/register_agent`,
        this.postJson({ name }),
      );
    } catch {
      // silent failure
    }
  }

  /**
   * Send a message to another agent.
   * Sends POST /send_message { to, subject, body, metadata? }.
   * Silently ignores all errors.
   */
  async sendMessage(
    to: string,
    subject: string,
    body: string,
    metadata?: Record<string, unknown>,
  ): Promise<void> {
    try {
      const payload: Record<string, unknown> = { to, subject, body };
      if (metadata !== undefined) {
        payload.metadata = metadata;
      }
      await this.fetchWithTimeout(
        `${this.baseUrl}/send_message`,
        this.postJson(payload),
      );
    } catch {
      // silent failure
    }
  }

  /**
   * Fetch messages from an agent's inbox.
   * GET /fetch_inbox?agent=<name>&limit=<n>&unread_only=<bool>
   * Returns [] on any failure.
   */
  async fetchInbox(
    agent: string,
    options?: { limit?: number; unreadOnly?: boolean },
  ): Promise<AgentMailMessage[]> {
    try {
      const params = new URLSearchParams({ agent });
      if (options?.limit !== undefined) {
        params.set("limit", String(options.limit));
      }
      if (options?.unreadOnly !== undefined) {
        params.set("unread_only", String(options.unreadOnly));
      }
      const url = `${this.baseUrl}/fetch_inbox?${params.toString()}`;
      const response = await this.fetchWithTimeout(url, { method: "GET" });
      if (!response.ok) {
        return [];
      }
      const messages = (await response.json()) as AgentMailMessage[];
      return messages;
    } catch {
      return [];
    }
  }

  /**
   * Request a file reservation lease for a set of paths.
   * POST /file_reservation_paths { paths, agent, duration_ms? }.
   * Returns { success: false } on any failure.
   */
  async fileReservation(
    paths: string[],
    lease: { agent: string; durationMs?: number },
  ): Promise<ReservationResult> {
    try {
      const payload: Record<string, unknown> = {
        paths,
        agent: lease.agent,
      };
      if (lease.durationMs !== undefined) {
        payload.duration_ms = lease.durationMs;
      }
      const response = await this.fetchWithTimeout(
        `${this.baseUrl}/file_reservation_paths`,
        this.postJson(payload),
      );
      if (!response.ok) {
        return { success: false };
      }
      return (await response.json()) as ReservationResult;
    } catch {
      return { success: false };
    }
  }

  /**
   * Release a previously-held file reservation.
   * POST /release_reservation { paths }.
   * Silently ignores all errors.
   */
  async releaseReservation(paths: string[]): Promise<void> {
    try {
      await this.fetchWithTimeout(
        `${this.baseUrl}/release_reservation`,
        this.postJson({ paths }),
      );
    } catch {
      // silent failure
    }
  }

  /**
   * Check whether the Agent Mail service is reachable.
   * GET /health → returns true if response is 2xx, false otherwise.
   */
  async healthCheck(): Promise<boolean> {
    try {
      const response = await this.fetchWithTimeout(
        `${this.baseUrl}/health`,
        { method: "GET" },
      );
      return response.ok;
    } catch {
      return false;
    }
  }
}
