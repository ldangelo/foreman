/**
 * SqliteMailClient — SQLite-backed drop-in replacement for AgentMailClient.
 *
 * Stores inter-agent messages in the existing ForemanStore messages table
 * instead of an external HTTP server. Messages are scoped by run_id.
 *
 * Implements the same duck-type interface as AgentMailClient so it can be
 * swapped in transparently in agent-worker.ts.
 */

import { ForemanStore } from "./store.js";

// ── Public types ──────────────────────────────────────────────────────────────

export interface AgentMailMessage {
  /** Unique message identifier. */
  id: string;
  /** Sender agent type / role. */
  from: string;
  /** Recipient agent type / role. */
  to: string;
  subject: string;
  body: string;
  /** ISO timestamp when the message was created. */
  receivedAt: string;
  acknowledged: boolean;
}

export class SqliteMailClient {
  /** The registered agent name for this instance. Used as sender for outgoing messages. */
  agentName: string | null = null;

  private store: ForemanStore | null = null;
  private runId: string | null = null;
  private projectPath: string | null = null;

  // ── Lifecycle ────────────────────────────────────────────────────────────────

  /**
   * Always returns true — SQLite is always available.
   */
  async healthCheck(): Promise<boolean> {
    return true;
  }

  /**
   * Initialize the store for the given project path.
   * Also stores the projectPath for later reference.
   * Must be called before sendMessage / fetchInbox.
   */
  async ensureProject(projectPath: string): Promise<void> {
    this.projectPath = projectPath;
    this.store = ForemanStore.forProject(projectPath);
  }

  /**
   * Set the run ID used to scope all messages.
   * Called from agent-worker after the run is created/known.
   */
  setRunId(runId: string): void {
    this.runId = runId;
  }

  /**
   * Returns roleHint as-is — no server-side name generation needed.
   * Also sets agentName to roleHint if not already set.
   */
  async ensureAgentRegistered(roleHint: string): Promise<string | null> {
    if (!this.agentName) {
      this.agentName = roleHint;
    }
    return roleHint;
  }

  // ── Messaging ────────────────────────────────────────────────────────────────

  /**
   * Send a message to another agent role.
   * Silently no-ops if runId or store is not initialized.
   */
  async sendMessage(to: string, subject: string, body: string): Promise<void> {
    if (!this.store || !this.runId) {
      return;
    }
    try {
      this.store.sendMessage(
        this.runId,
        this.agentName ?? "foreman",
        to,
        subject,
        body,
      );
    } catch {
      // Silent failure — messaging is non-critical infrastructure
    }
  }

  /**
   * Fetch unread messages for an agent.
   * Returns [] if not initialized or on any error.
   */
  async fetchInbox(
    agent: string,
    options?: { limit?: number },
  ): Promise<AgentMailMessage[]> {
    if (!this.store || !this.runId) {
      return [];
    }
    try {
      // Fetch unread messages for this agent
      const messages = this.store.getMessages(this.runId, agent, true);
      const limit = options?.limit ?? 50;
      const sliced = messages.slice(0, limit);
      return sliced.map((m) => ({
        id: m.id,
        from: m.sender_agent_type,
        to: m.recipient_agent_type,
        subject: m.subject,
        body: m.body,
        receivedAt: m.created_at,
        acknowledged: m.read === 1,
      }));
    } catch {
      return [];
    }
  }

  /**
   * Mark a message as read by its ID.
   * Silent failure.
   */
  async acknowledgeMessage(_agent: string, messageId: number): Promise<void> {
    if (!this.store) return;
    try {
      this.store.markMessageRead(String(messageId));
    } catch {
      // Silent failure
    }
  }

  // ── File reservation no-ops ──────────────────────────────────────────────────

  /** No-op — file reservation is handled externally. */
  async reserveFiles(
    _paths: string[],
    _agentName: string,
    _leaseSecs?: number,
  ): Promise<void> {
    // No-op for SQLite backend
  }

  /** No-op — file reservation is handled externally. */
  async releaseFiles(_paths: string[], _agentName: string): Promise<void> {
    // No-op for SQLite backend
  }
}
