import type { AgentMailClient, AgentMailMessage } from "./agent-mail-client.js";
import { ElixirServerClient, type ElixirInboxMessage } from "./elixir-server-client.js";
import { ElixirServerManager } from "./elixir-server-manager.js";

function asString(value: unknown, fallback = ""): string {
  return typeof value === "string" ? value : fallback;
}

function asBool(value: unknown): boolean {
  return value === true;
}

/** Agent mail client backed by the Elixir event/projection API. */
export class ElixirMailClient implements AgentMailClient {
  agentName: string | null = null;
  private runId: string | null = null;
  private clientPromise: Promise<ElixirServerClient> | null = null;

  constructor(
    private readonly client?: ElixirServerClient,
  ) {}

  async healthCheck(): Promise<boolean> {
    await this.getClient();
    return true;
  }

  async ensureProject(_projectPath: string): Promise<void> {
    await this.getClient();
  }

  setRunId(runId: string): void {
    this.runId = runId;
  }

  async ensureAgentRegistered(roleHint: string): Promise<string | null> {
    if (!this.agentName) this.agentName = roleHint;
    return roleHint;
  }

  async sendMessage(to: string, subject: string, body: string): Promise<void> {
    if (!this.runId) return;
    const from = this.agentName ?? "foreman";
    const response = await (await this.getClient()).sendCommand({
      command_id: `inbox-send-${this.runId}-${Date.now()}-${Math.random().toString(16).slice(2)}`,
      command_type: "inbox.send",
      payload: {
        run_id: this.runId,
        from,
        to,
        subject,
        body,
        worker_supports_receiving: true,
      },
    });
    if (!response.ok) {
      throw new Error(response.error.message);
    }
  }

  async fetchInbox(agent: string, options?: { limit?: number }): Promise<AgentMailMessage[]> {
    if (!this.runId) return [];
    const inbox = await (await this.getClient()).listInbox({ runId: this.runId, limit: options?.limit });
    return inbox
      .filter((message) => this.recipient(message) === agent)
      .map((message) => ({
        id: asString(message.message_id ?? message.id),
        from: this.sender(message),
        to: this.recipient(message),
        subject: asString(message.subject, "message"),
        body: asString(message.body),
        receivedAt: asString(message.created_at ?? message.occurred_at, new Date(0).toISOString()),
        acknowledged: !asBool(message.unread),
      }));
  }

  async acknowledgeMessage(_agent: string, _messageId: number): Promise<void> {
    // Delivery updates are not required for current worker mail semantics.
  }

  async reserveFiles(_paths: string[], _agentName: string, _leaseSecs?: number): Promise<void> {
    // File reservations are handled by the worker process, not Elixir inbox.
  }

  async releaseFiles(_paths: string[], _agentName: string): Promise<void> {
    // File reservations are handled by the worker process, not Elixir inbox.
  }

  private sender(message: ElixirInboxMessage): string {
    return asString(message.from ?? message.sender ?? message.sender_agent_type, "foreman");
  }

  private recipient(message: ElixirInboxMessage): string {
    return asString(message.to ?? message.recipient ?? message.recipient_agent_type, "worker");
  }

  private async getClient(): Promise<ElixirServerClient> {
    if (this.client) return this.client;
    if (this.clientPromise) return this.clientPromise;

    this.clientPromise = process.env.FOREMAN_SERVER_URL
      ? Promise.resolve(new ElixirServerClient(process.env.FOREMAN_SERVER_URL, process.env.FOREMAN_WORKER_EVENT_TOKEN ?? process.env.FOREMAN_SERVER_AUTH_TOKEN))
      : new ElixirServerManager().ensureRunning().then((status) => (
          new ElixirServerClient(status.url, process.env.FOREMAN_WORKER_EVENT_TOKEN ?? process.env.FOREMAN_SERVER_AUTH_TOKEN)
        ));

    return this.clientPromise;
  }
}
