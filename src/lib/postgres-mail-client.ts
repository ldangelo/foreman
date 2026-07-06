import type { AgentMailClient, AgentMailMessage } from "./agent-mail-client.js";
import { listRegisteredProjects } from "../cli/commands/project-task-support.js";

/**
 * Registered-project mail client placeholder.
 *
 * Legacy Postgres mail storage was removed. Until Elixir exposes agent mail APIs,
 * this client preserves pipeline progress without opening a direct DB pool.
 */
export class PostgresMailClient implements AgentMailClient {
  agentName: string | null = null;
  private runId: string | null = null;
  private projectPath: string | null = null;

  async healthCheck(): Promise<boolean> {
    return true;
  }

  async ensureProject(projectPath: string): Promise<void> {
    this.projectPath = projectPath;
    const projects = await listRegisteredProjects();
    const project = projects.find((record) => record.path === projectPath);
    if (!project) throw new Error(`Project at '${projectPath}' is not registered with the daemon.`);
  }

  setRunId(runId: string): void {
    this.runId = runId;
  }

  async ensureAgentRegistered(roleHint: string): Promise<string | null> {
    if (!this.agentName) this.agentName = roleHint;
    return roleHint;
  }

  async sendMessage(_to: string, _subject: string, _body: string): Promise<void> {
    void this.projectPath;
    void this.runId;
  }

  async fetchInbox(_agent: string, _options?: { limit?: number }): Promise<AgentMailMessage[]> {
    return [];
  }

  async acknowledgeMessage(_agent: string, _messageId: number): Promise<void> {}

  async reserveFiles(_paths: string[], _agentName: string, _leaseSecs?: number): Promise<void> {}

  async releaseFiles(_paths: string[], _agentName: string): Promise<void> {}
}
