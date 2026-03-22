/**
 * AgentMailClient — HTTP client for the Agent Mail inter-agent messaging service.
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

import { readFileSync, writeFileSync } from "node:fs";
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

export const DEFAULT_AGENT_MAIL_CONFIG: {
  readonly baseUrl: string;
  readonly timeoutMs: number;
  readonly enabled: boolean;
  readonly projectKey: string;
} = {
  baseUrl: "http://localhost:8766",
  timeoutMs: 3000,
  enabled: true,
  projectKey: process.cwd(),
};

// ── File-based config shape ───────────────────────────────────────────────────

interface FileConfig {
  baseUrl?: string;
  timeoutMs?: number;
  enabled?: boolean;
  projectKey?: string;
  /** Persistent name for the foreman orchestrator agent (adjective+noun, e.g. "PearlHawk"). */
  foremanAgentName?: string;
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
  private projectKey: string;
  private readonly bearerToken: string | undefined;
  private rpcId = 0;
  /**
   * The registered Agent Mail name for this instance (adjective+noun, e.g. "PearlHawk").
   * Set after ensureProject() + ensureAgentRegistered() succeed.
   * Used as sender_name for outgoing messages.
   */
  agentName: string | null = null;
  /**
   * Role-to-registered-name mapping for addressing messages.
   * Keys are logical role names ("foreman", "developer-bd-xxx"), values are adjective+noun names.
   */
  private agentRegistry: Map<string, string> = new Map();

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

    // Pre-load foreman agent name from file config if available
    if (fileConfig?.foremanAgentName) {
      this.agentName = fileConfig.foremanAgentName;
      this.agentRegistry.set("foreman", fileConfig.foremanAgentName);
    }
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
      // After successful project registration, use the absolute path as project_key
      // for all subsequent calls (send_message, fetch_inbox, register_agent, etc.)
      this.projectKey = projectPath;

      // If we don't have a foreman agent name yet, register the orchestrator now.
      if (!this.agentName) {
        await this.ensureAgentRegistered("foreman", projectPath);
      }
    } catch {
      // Silent failure — mail is non-critical infrastructure
    }
  }

  /**
   * Register this process as a named agent in Agent Mail.
   * Auto-generates an adjective+noun name (Agent Mail requirement).
   * Persists the generated name to .foreman/agent-mail.json under `foremanAgentName`
   * when roleHint="foreman" so subsequent startups reuse the same mailbox.
   *
   * @param roleHint - Logical role (used as program description and for caching)
   * @param projectPath - Absolute project path (for config file location)
   * @returns The generated agent name, or null on failure.
   */
  async ensureAgentRegistered(roleHint: string, projectPath?: string): Promise<string | null> {
    // Return cached name if available
    const cached = this.agentRegistry.get(roleHint);
    if (cached) return cached;

    try {
      const result = await this.mcpCall("register_agent", {
        project_key: this.projectKey,
        program: "foreman",
        task_description: `Foreman ${roleHint} agent`,
        model: "claude-sonnet-4-6",
        // Deliberately omit "name" — Agent Mail auto-generates a valid adjective+noun name
      }) as Record<string, unknown>;

      const generatedName = String(result["name"] ?? "");
      if (!generatedName) return null;

      // Cache the name for this role
      this.agentRegistry.set(roleHint, generatedName);

      // For the foreman orchestrator, set as the primary agent name and persist to disk
      if (roleHint === "foreman") {
        this.agentName = generatedName;
        if (projectPath) {
          this.persistForemanAgentName(generatedName, projectPath);
        }
      }

      return generatedName;
    } catch {
      return null;
    }
  }

  /** Persist the foreman agent name to .foreman/agent-mail.json for cross-process reuse. */
  private persistForemanAgentName(name: string, projectPath: string): void {
    try {
      const configPath = join(projectPath, ".foreman", "agent-mail.json");
      let existing: Record<string, unknown> = {};
      try {
        existing = JSON.parse(readFileSync(configPath, "utf-8")) as Record<string, unknown>;
      } catch {
        // File may not exist yet — start fresh
      }
      existing["foremanAgentName"] = name;
      writeFileSync(configPath, JSON.stringify(existing, null, 2) + "\n", "utf-8");
    } catch {
      // Non-fatal — name will just be re-registered on next startup
    }
  }

  /**
   * Register an agent with the project.
   * Auto-generates the adjective+noun name (Agent Mail requirement).
   * Caches the returned name under the provided roleHint for subsequent sends.
   * Silent failure.
   */
  async registerAgent(roleHint: string): Promise<void> {
    // Use ensureAgentRegistered — it handles caching and generation
    await this.ensureAgentRegistered(roleHint);
  }

  /**
   * Resolve a logical role name to a registered Agent Mail agent name.
   * Returns null if the role hasn't been registered yet.
   */
  resolveAgentName(roleHint: string): string | null {
    return this.agentRegistry.get(roleHint) ?? null;
  }

  /**
   * Send a message from this agent to a recipient.
   * Resolves logical role names (e.g. "foreman") to registered adjective+noun names.
   * Silent failure.
   */
  async sendMessage(to: string, subject: string, body: string): Promise<void> {
    const senderName = this.agentName;
    const recipientName = this.agentRegistry.get(to) ?? to;

    if (!senderName) {
      // Can't send without a registered sender identity
      return;
    }

    try {
      await this.mcpCall("send_message", {
        project_key: this.projectKey,
        sender_name: senderName,
        to: [recipientName],
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
    // Resolve logical role name to registered agent name
    const agentName = this.agentRegistry.get(agent) ?? agent;
    try {
      const result = await this.mcpCall("fetch_inbox", {
        project_key: this.projectKey,
        agent_name: agentName,
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
   * Reserve files for exclusive use during a pipeline phase.
   * Convenience wrapper around fileReservation().
   * Silent failure — returns void (ignores conflict details).
   */
  async reserveFiles(paths: string[], agentName: string, leaseSecs?: number): Promise<void> {
    await this.fileReservation(paths, {
      agent: agentName,
      durationMs: leaseSecs !== undefined ? leaseSecs * 1000 : undefined,
    });
    // Result intentionally ignored — fire-and-forget reservation
  }

  /**
   * Release file reservations held by an agent.
   * Convenience wrapper around releaseReservation().
   * Silent failure.
   */
  async releaseFiles(paths: string[], agentName: string): Promise<void> {
    await this.releaseReservation(paths, agentName);
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
