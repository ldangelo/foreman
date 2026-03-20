/**
 * AgentMailClient — HTTP client for the Agent Mail service (port 8765 FastMCP).
 *
 * TRD-020: Agent Mail HTTP Client
 *
 * Design principles:
 *   - Fire-and-forget with AbortController timeout (default 3000ms)
 *   - Silent failure: ALL errors (network, timeout, non-2xx) are caught and swallowed
 *   - fetchInbox() returns [] on any failure
 *   - healthCheck() returns false on any failure
 *   - Base URL resolved from: constructor config → AGENT_MAIL_URL env var → default
 *   - Project key resolved from: constructor config → AGENT_MAIL_PROJECT env var → file config → "foreman"
 *   - Bearer token resolved from: constructor config → AGENT_MAIL_TOKEN env var → file config
 *
 * Transport: FastMCP streamable HTTP transport at POST /mcp using JSON-RPC 2.0.
 * The real server is https://github.com/Dicklesworthstone/mcp_agent_mail.
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
  /** Timeout in ms for all requests. Defaults to 3000. */
  timeoutMs?: number;
  /** Project key for the Agent Mail service. Defaults to AGENT_MAIL_PROJECT env var or "foreman". */
  projectKey?: string;
  /** Bearer token for authentication. Defaults to AGENT_MAIL_TOKEN env var. */
  bearerToken?: string;
}

/** Shape of the optional .foreman/agent-mail.json config file. */
interface AgentMailFileConfig {
  baseUrl?: string;
  timeoutMs?: number;
  enabled?: boolean;
  projectKey?: string;
  bearerToken?: string;
}

/** JSON-RPC 2.0 response shape returned by FastMCP /mcp endpoint. */
interface JsonRpcResponse {
  jsonrpc: "2.0";
  id: number;
  result?: {
    content: Array<{ type: string; text: string }>;
  };
  error?: {
    code: number;
    message: string;
  };
}

/** Raw message shape returned by the real fetch_inbox tool. */
interface RawMailMessage {
  id: number;
  sender_name?: string;
  from?: string;
  recipients?: string[];
  to?: string;
  subject: string;
  body_md?: string;
  body?: string;
  created_at?: string;
  received_at?: string;
  acknowledged: boolean;
}

// ── Default config file content (written by init command) ─────────────────────

export const DEFAULT_AGENT_MAIL_CONFIG: AgentMailFileConfig = {
  baseUrl: "http://localhost:8765",
  timeoutMs: 3000,
  enabled: true,
  projectKey: "foreman",
};

// ── Helpers ───────────────────────────────────────────────────────────────────

const DEFAULT_BASE_URL = "http://localhost:8765";
const DEFAULT_TIMEOUT_MS = 3000;
const DEFAULT_PROJECT_KEY = "foreman";

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

/**
 * Resolve the project key from: constructor config → env var → file config → default.
 */
function resolveProjectKey(configProjectKey: string | undefined): string {
  if (configProjectKey !== undefined && configProjectKey !== "") {
    return configProjectKey;
  }
  const envKey = process.env.AGENT_MAIL_PROJECT;
  if (envKey !== undefined && envKey !== "") {
    return envKey;
  }
  const fileConfig = loadFileConfig();
  if (fileConfig?.projectKey !== undefined && fileConfig.projectKey !== "") {
    return fileConfig.projectKey;
  }
  return DEFAULT_PROJECT_KEY;
}

/**
 * Resolve the bearer token from: constructor config → env var → file config → undefined.
 */
function resolveBearerToken(configToken: string | undefined): string | undefined {
  if (configToken !== undefined && configToken !== "") {
    return configToken;
  }
  const envToken = process.env.AGENT_MAIL_TOKEN;
  if (envToken !== undefined && envToken !== "") {
    return envToken;
  }
  const fileConfig = loadFileConfig();
  if (fileConfig?.bearerToken !== undefined && fileConfig.bearerToken !== "") {
    return fileConfig.bearerToken;
  }
  return undefined;
}

/**
 * Map a raw server message to the AgentMailMessage interface expected by callers.
 */
function mapMessage(raw: RawMailMessage): AgentMailMessage {
  return {
    id: String(raw.id),
    from: raw.sender_name ?? raw.from ?? "",
    to: raw.recipients?.[0] ?? raw.to ?? "",
    subject: raw.subject,
    body: raw.body_md ?? raw.body ?? "",
    receivedAt: raw.received_at ?? raw.created_at ?? new Date().toISOString(),
    acknowledged: raw.acknowledged,
  };
}

// ── AgentMailClient ────────────────────────────────────────────────────────────

export class AgentMailClient {
  private readonly baseUrl: string;
  private readonly timeoutMs: number;
  private readonly projectKey: string;
  private readonly bearerToken: string | undefined;

  constructor(config?: AgentMailClientConfig) {
    this.baseUrl = resolveBaseUrl(config?.baseUrl);
    this.timeoutMs = resolveTimeoutMs(config?.timeoutMs);
    this.projectKey = resolveProjectKey(config?.projectKey);
    this.bearerToken = resolveBearerToken(config?.bearerToken);
  }

  // ── Internal MCP call helper ──────────────────────────────────────────────

  /**
   * Call a FastMCP tool via JSON-RPC 2.0 POST /mcp.
   * Extracts and JSON-parses the result from result.content[0].text.
   * Throws on any failure — callers are responsible for catching.
   */
  private async mcpCall(toolName: string, args: Record<string, unknown>): Promise<unknown> {
    const controller = new AbortController();
    const timerId = setTimeout(() => controller.abort(), this.timeoutMs);

    const headers: Record<string, string> = {
      "Content-Type": "application/json",
    };
    if (this.bearerToken !== undefined) {
      headers["Authorization"] = `Bearer ${this.bearerToken}`;
    }

    try {
      const response = await fetch(`${this.baseUrl}/mcp`, {
        method: "POST",
        headers,
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: {
            name: toolName,
            arguments: args,
          },
        }),
        signal: controller.signal,
      });

      if (!response.ok) {
        throw new Error(`HTTP ${response.status} from /mcp`);
      }

      const rpc = (await response.json()) as JsonRpcResponse;

      if (rpc.error !== undefined) {
        throw new Error(`MCP error ${rpc.error.code}: ${rpc.error.message}`);
      }

      const text = rpc.result?.content?.[0]?.text;
      if (text === undefined) {
        throw new Error("MCP response missing result.content[0].text");
      }

      return JSON.parse(text) as unknown;
    } finally {
      clearTimeout(timerId);
    }
  }

  // ── Public API ────────────────────────────────────────────────────────────

  /**
   * Ensure the project exists in the Agent Mail service.
   * Silently ignores all errors.
   */
  async ensureProject(): Promise<void> {
    try {
      await this.mcpCall("ensure_project", { project_key: this.projectKey });
    } catch {
      // silent failure
    }
  }

  /**
   * Register an agent with the mail service.
   * Silently ignores all errors.
   */
  async registerAgent(name: string): Promise<void> {
    try {
      await this.mcpCall("register_agent", {
        project_key: this.projectKey,
        name,
        program: "foreman",
        model: "claude-sonnet-4-6",
      });
    } catch {
      // silent failure
    }
  }

  /**
   * Send a message to another agent.
   * Silently ignores all errors.
   */
  async sendMessage(
    to: string,
    subject: string,
    body: string,
  ): Promise<void> {
    try {
      await this.mcpCall("send_message", {
        project_key: this.projectKey,
        sender_name: "foreman",
        to: [to],
        subject,
        body_md: body,
      });
    } catch {
      // silent failure
    }
  }

  /**
   * Fetch messages from an agent's inbox.
   * Returns [] on any failure.
   */
  async fetchInbox(
    agent: string,
    options?: { limit?: number; unreadOnly?: boolean },
  ): Promise<AgentMailMessage[]> {
    try {
      const result = await this.mcpCall("fetch_inbox", {
        project_key: this.projectKey,
        agent_name: agent,
        limit: options?.limit ?? 20,
        urgent_only: options?.unreadOnly ?? false,
        include_bodies: true,
      });
      const rawMessages = result as RawMailMessage[];
      return rawMessages.map(mapMessage);
    } catch {
      return [];
    }
  }

  /**
   * Request a file reservation lease for a set of paths.
   * Returns { success: false } on any failure.
   */
  async fileReservation(
    paths: string[],
    lease: { agent: string; durationMs?: number },
  ): Promise<ReservationResult> {
    try {
      const result = await this.mcpCall("file_reservation_paths", {
        project_key: this.projectKey,
        agent_name: lease.agent,
        paths,
        ttl_seconds: lease.durationMs !== undefined ? Math.ceil(lease.durationMs / 1000) : 3600,
        exclusive: true,
        reason: "foreman-phase-reservation",
      });
      return result as ReservationResult;
    } catch {
      return { success: false };
    }
  }

  /**
   * Release a previously-held file reservation.
   * Silently ignores all errors.
   */
  async releaseReservation(paths: string[], agentName: string): Promise<void> {
    try {
      await this.mcpCall("release_file_reservations", {
        project_key: this.projectKey,
        agent_name: agentName,
        paths,
      });
    } catch {
      // silent failure
    }
  }

  /**
   * Check whether the Agent Mail service is reachable.
   * GET /health → returns true if response is 2xx, false otherwise.
   */
  async healthCheck(): Promise<boolean> {
    const controller = new AbortController();
    const timerId = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const response = await fetch(`${this.baseUrl}/health`, {
        method: "GET",
        signal: controller.signal,
      });
      return response.ok;
    } catch {
      return false;
    } finally {
      clearTimeout(timerId);
    }
  }
}
