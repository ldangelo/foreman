/**
 * AgentMailClient — HTTP client for the mcp_agent_mail FastMCP server.
 *
 * The Python server exposes a JSON-RPC 2.0 endpoint at POST /mcp.
 * All methods catch errors silently so they never block or crash the pipeline.
 *
 * Config resolution priority (highest to lowest):
 *   1. Constructor args
 *   2. Env vars (AGENT_MAIL_URL, AGENT_MAIL_TOKEN, AGENT_MAIL_PROJECT)
 *   3. .foreman/agent-mail.json
 *   4. Built-in defaults
 */

import { readFileSync } from "node:fs";
import { join } from "node:path";

// ── Public types ──────────────────────────────────────────────────────────────

export interface AgentMailMessage {
  /** Mapped from server's numeric id (stringified). */
  id: string;
  /** Mapped from sender_name. */
  from: string;
  /** Mapped from recipients[0]. */
  to: string;
  subject: string;
  /** Mapped from body_md. */
  body: string;
  /** Mapped from received_at or created_at. */
  receivedAt: string;
  acknowledged: boolean;
}

export interface ReservationResult {
  success: boolean;
  conflicts?: Array<{ path: string; heldBy: string; expiresAt: string }>;
}

export interface AgentMailClientConfig {
  baseUrl?: string;
  timeoutMs?: number;
  projectKey?: string;
  bearerToken?: string;
}

export const DEFAULT_AGENT_MAIL_CONFIG = {
  baseUrl: "http://localhost:8766",
  timeoutMs: 3000,
  enabled: true,
  projectKey: "foreman",
} as const;

// ── File-based config shape ───────────────────────────────────────────────────

interface FileConfig {
  baseUrl?: string;
  timeoutMs?: number;
  enabled?: boolean;
  projectKey?: string;
}

// ── JSON-RPC envelope types ───────────────────────────────────────────────────

interface JsonRpcRequest {
  jsonrpc: "2.0";
  id: number;
  method: "tools/call";
  params: {
    name: string;
    arguments: Record<string, unknown>;
  };
}

interface JsonRpcSuccessResponse {
  jsonrpc: "2.0";
  id: number;
  result: {
    content: Array<{ type: string; text: string }>;
    isError?: boolean;
  };
}

interface JsonRpcErrorResponse {
  jsonrpc: "2.0";
  id: number;
  error: { code: number; message: string };
}

type JsonRpcResponse = JsonRpcSuccessResponse | JsonRpcErrorResponse;

// ── AgentMailClient ───────────────────────────────────────────────────────────

export class AgentMailClient {
  private readonly baseUrl: string;
  private readonly timeoutMs: number;
  private readonly projectKey: string;
  private readonly bearerToken: string | undefined;
  private rpcId = 0;

  constructor(config: AgentMailClientConfig = {}) {
    // Load file-based config (lowest priority above defaults)
    const fileConfig = AgentMailClient.loadFileConfig();

    // Resolve each setting: constructor → env → file → default
    this.baseUrl =
      config.baseUrl ??
      process.env.AGENT_MAIL_URL ??
      fileConfig?.baseUrl ??
      DEFAULT_AGENT_MAIL_CONFIG.baseUrl;

    this.timeoutMs =
      config.timeoutMs ??
      fileConfig?.timeoutMs ??
      DEFAULT_AGENT_MAIL_CONFIG.timeoutMs;

    this.projectKey =
      config.projectKey ??
      process.env.AGENT_MAIL_PROJECT ??
      fileConfig?.projectKey ??
      DEFAULT_AGENT_MAIL_CONFIG.projectKey;

    this.bearerToken =
      config.bearerToken ?? process.env.AGENT_MAIL_TOKEN ?? undefined;
  }

  // ── Private helpers ─────────────────────────────────────────────────────────

  private static loadFileConfig(): FileConfig | null {
    // Look for .foreman/agent-mail.json relative to cwd
    const candidates = [
      join(process.cwd(), ".foreman", "agent-mail.json"),
    ];
    for (const p of candidates) {
      try {
        const raw = readFileSync(p, "utf-8");
        return JSON.parse(raw) as FileConfig;
      } catch {
        // Not found or invalid JSON — try next candidate
      }
    }
    return null;
  }

  /**
   * Send a JSON-RPC 2.0 tools/call to POST /mcp.
   * Throws on network error or server-side error (isError=true).
   */
  private async mcpCall(
    toolName: string,
    args: Record<string, unknown>,
  ): Promise<unknown> {
    const id = ++this.rpcId;
    const body: JsonRpcRequest = {
      jsonrpc: "2.0",
      id,
      method: "tools/call",
      params: { name: toolName, arguments: args },
    };

    const headers: Record<string, string> = {
      "Content-Type": "application/json",
    };
    if (this.bearerToken) {
      headers["Authorization"] = `Bearer ${this.bearerToken}`;
    }

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);

    let response: Response;
    try {
      response = await fetch(`${this.baseUrl}/mcp`, {
        method: "POST",
        headers,
        body: JSON.stringify(body),
        signal: controller.signal,
      });
    } finally {
      clearTimeout(timer);
    }

    if (!response.ok) {
      throw new Error(`HTTP ${response.status} from agent-mail /mcp`);
    }

    const envelope = (await response.json()) as JsonRpcResponse;

    if ("error" in envelope) {
      throw new Error(`JSON-RPC error ${envelope.error.code}: ${envelope.error.message}`);
    }

    const successEnvelope = envelope as JsonRpcSuccessResponse;
    if (successEnvelope.result.isError) {
      const text = successEnvelope.result.content?.[0]?.text ?? "(no details)";
      throw new Error(`agent-mail tool error: ${text}`);
    }

    const text = successEnvelope.result.content?.[0]?.text ?? "{}";
    try {
      return JSON.parse(text);
    } catch {
      // Some tools return plain strings — return as-is
      return text;
    }
  }

  // ── Public API ──────────────────────────────────────────────────────────────

  /**
   * Ensure the project is registered with the agent mail server.
   * Uses `human_key` (absolute path), NOT `project_key`.
   * Silent failure.
   */
  async ensureProject(projectPath: string): Promise<void> {
    try {
      await this.mcpCall("ensure_project", { human_key: projectPath });
    } catch {
      // Silent failure — mail is non-critical infrastructure
    }
  }

  /**
   * Register an agent with the project.
   * Silent failure.
   */
  async registerAgent(name: string): Promise<void> {
    try {
      await this.mcpCall("register_agent", {
        project_key: this.projectKey,
        program: "foreman",
        model: "claude-sonnet-4-6",
        name,
      });
    } catch {
      // Silent failure
    }
  }

  /**
   * Send a message from foreman to an agent.
   * Silent failure.
   */
  async sendMessage(to: string, subject: string, body: string): Promise<void> {
    try {
      await this.mcpCall("send_message", {
        project_key: this.projectKey,
        sender_name: "foreman",
        to: [to],
        subject,
        body_md: body,
      });
    } catch {
      // Silent failure
    }
  }

  /**
   * Fetch an agent's inbox.
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
        urgent_only: false,
        include_bodies: true,
      });

      // Server returns an array of message objects
      const messages = Array.isArray(result) ? result : [];
      return messages.map(
        (m: Record<string, unknown>): AgentMailMessage => ({
          id: String(m["id"] ?? ""),
          from: String(m["sender_name"] ?? m["from"] ?? ""),
          to: String(
            Array.isArray(m["recipients"])
              ? (m["recipients"] as unknown[])[0]
              : (m["to"] ?? ""),
          ),
          subject: String(m["subject"] ?? ""),
          body: String(m["body_md"] ?? m["body"] ?? ""),
          receivedAt: String(m["received_at"] ?? m["created_at"] ?? new Date().toISOString()),
          acknowledged: Boolean(m["acknowledged"] ?? false),
        }),
      );
    } catch {
      return [];
    }
  }

  /**
   * Acknowledge a message by ID.
   * Silent failure.
   */
  async acknowledgeMessage(agent: string, messageId: number): Promise<void> {
    try {
      await this.mcpCall("acknowledge_message", {
        project_key: this.projectKey,
        agent_name: agent,
        message_id: messageId,
      });
    } catch {
      // Silent failure
    }
  }

  /**
   * Reserve files for exclusive use during a pipeline phase.
   * Returns { success: false } on any failure.
   */
  async fileReservation(
    paths: string[],
    lease: { agent: string; durationMs?: number },
  ): Promise<ReservationResult> {
    try {
      const ttlSeconds = Math.round((lease.durationMs ?? 300_000) / 1000);
      const result = (await this.mcpCall("file_reservation_paths", {
        project_key: this.projectKey,
        agent_name: lease.agent,
        paths,
        ttl_seconds: ttlSeconds,
        exclusive: true,
        reason: "foreman-phase-reservation",
      })) as Record<string, unknown>;

      const conflicts = Array.isArray(result["conflicts"])
        ? (result["conflicts"] as Array<Record<string, unknown>>).map((c) => ({
            path: String(c["path"] ?? ""),
            heldBy: String(c["held_by"] ?? c["heldBy"] ?? ""),
            expiresAt: String(c["expires_at"] ?? c["expiresAt"] ?? ""),
          }))
        : undefined;

      return {
        success: Boolean(result["success"] ?? true),
        conflicts: conflicts && conflicts.length > 0 ? conflicts : undefined,
      };
    } catch {
      return { success: false };
    }
  }

  /**
   * Release file reservations held by an agent.
   * Silent failure.
   */
  async releaseReservation(paths: string[], agentName: string): Promise<void> {
    try {
      await this.mcpCall("release_file_reservations", {
        project_key: this.projectKey,
        agent_name: agentName,
        paths,
      });
    } catch {
      // Silent failure
    }
  }

  /**
   * Health check: GET /health.
   * Returns true on 2xx, false otherwise.
   */
  async healthCheck(): Promise<boolean> {
    try {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), this.timeoutMs);
      let response: Response;
      try {
        response = await fetch(`${this.baseUrl}/health`, {
          method: "GET",
          signal: controller.signal,
        });
      } finally {
        clearTimeout(timer);
      }
      return response.ok;
    } catch {
      return false;
    }
  }
}
