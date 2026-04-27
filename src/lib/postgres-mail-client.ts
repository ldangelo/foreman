import { PostgresStore } from "./postgres-store.js";
import type { AgentMailClient, AgentMailMessage } from "./sqlite-mail-client.js";
import { listRegisteredProjects } from "../cli/commands/project-task-support.js";

export class PostgresMailClient implements AgentMailClient {
  agentName: string | null = null;
  private store: PostgresStore | null = null;
  private runId: string | null = null;
  private projectPath: string | null = null;

  async healthCheck(): Promise<boolean> {
    return true;
  }

  async ensureProject(projectPath: string): Promise<void> {
    this.projectPath = projectPath;
    const projects = await listRegisteredProjects();
    const project = projects.find((record) => record.path === projectPath);
    if (!project) {
      throw new Error(`Project at '${projectPath}' is not registered with the daemon.`);
    }
    this.store = PostgresStore.forProject(project.id);
  }

  setRunId(runId: string): void {
    this.runId = runId;
  }

  async ensureAgentRegistered(roleHint: string): Promise<string | null> {
    if (!this.agentName) {
      this.agentName = roleHint;
    }
    return roleHint;
  }

  async sendMessage(to: string, subject: string, body: string): Promise<void> {
    if (!this.store || !this.runId) return;
    await this.store.sendMessage(this.runId, this.agentName ?? "foreman", to, subject, body);
  }

  async fetchInbox(agent: string, options?: { limit?: number }): Promise<AgentMailMessage[]> {
    if (!this.store || !this.runId) return [];
    const messages = await this.store.getMessages(this.runId, agent, true);
    const sliced = messages.slice(0, options?.limit ?? 50);
    return sliced.map((m) => ({
      id: m.id,
      from: m.sender_agent_type,
      to: m.recipient_agent_type,
      subject: m.subject,
      body: m.body,
      receivedAt: m.created_at,
      acknowledged: m.read === 1,
    }));
  }

  async acknowledgeMessage(_agent: string, messageId: number): Promise<void> {
    if (!this.store) return;
    await this.store.markMessageRead(String(messageId));
  }

  async reserveFiles(_paths: string[], _agentName: string, _leaseSecs?: number): Promise<void> {
    // No-op for now.
  }

  async releaseFiles(_paths: string[], _agentName: string): Promise<void> {
    // No-op for now.
  }
}
