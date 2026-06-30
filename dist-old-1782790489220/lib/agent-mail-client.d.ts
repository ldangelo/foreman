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
    fetchInbox(agent: string, options?: {
        limit?: number;
    }): Promise<AgentMailMessage[]>;
    acknowledgeMessage(agent: string, messageId: number): Promise<void>;
    reserveFiles(paths: string[], agentName: string, leaseSecs?: number): Promise<void>;
    releaseFiles(paths: string[], agentName: string): Promise<void>;
}
export declare class NullAgentMailClient implements AgentMailClient {
    agentName: string | null;
    healthCheck(): Promise<boolean>;
    ensureProject(_projectPath: string): Promise<void>;
    setRunId(_runId: string): void;
    ensureAgentRegistered(roleHint: string): Promise<string | null>;
    sendMessage(_to: string, _subject: string, _body: string): Promise<void>;
    fetchInbox(_agent: string, _options?: {
        limit?: number;
    }): Promise<AgentMailMessage[]>;
    acknowledgeMessage(_agent: string, _messageId: number): Promise<void>;
    reserveFiles(_paths: string[], _agentName: string, _leaseSecs?: number): Promise<void>;
    releaseFiles(_paths: string[], _agentName: string): Promise<void>;
}
//# sourceMappingURL=agent-mail-client.d.ts.map