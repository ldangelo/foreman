export interface AgentMailMessage {
  id: string;
  from: string;
  to: string;
  subject: string;
  body: string;
  receivedAt: string;
  acknowledged: boolean;
}

export interface AgentMailClient {
  agentName: string | null;
  healthCheck(): Promise<boolean>;
  ensureProject(projectPath: string): Promise<void>;
  setRunId(runId: string): void;
  ensureAgentRegistered(roleHint: string): Promise<string | null>;
  sendMessage(to: string, subject: string, body: string): Promise<void>;
  fetchInbox(agent: string, options?: { limit?: number }): Promise<AgentMailMessage[]>;
  acknowledgeMessage(agent: string, messageId: number): Promise<void>;
  reserveFiles(paths: string[], agentName: string, leaseSecs?: number): Promise<void>;
  releaseFiles(paths: string[], agentName: string): Promise<void>;
}

export class NullAgentMailClient implements AgentMailClient {
  agentName: string | null = null;

  async healthCheck(): Promise<boolean> { return true; }
  async ensureProject(_projectPath: string): Promise<void> { /* no-op */ }
  setRunId(_runId: string): void { /* no-op */ }
  async ensureAgentRegistered(roleHint: string): Promise<string | null> {
    this.agentName = roleHint;
    return roleHint;
  }
  async sendMessage(_to: string, _subject: string, _body: string): Promise<void> { /* no-op */ }
  async fetchInbox(_agent: string, _options?: { limit?: number }): Promise<AgentMailMessage[]> { return []; }
  async acknowledgeMessage(_agent: string, _messageId: number): Promise<void> { /* no-op */ }
  async reserveFiles(_paths: string[], _agentName: string, _leaseSecs?: number): Promise<void> { /* no-op */ }
  async releaseFiles(_paths: string[], _agentName: string): Promise<void> { /* no-op */ }
}
