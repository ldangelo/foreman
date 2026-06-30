import type { AgentMailClient, AgentMailMessage } from "./agent-mail-client.js";
export declare class PostgresMailClient implements AgentMailClient {
    agentName: string | null;
    private store;
    private runId;
    private projectPath;
    healthCheck(): Promise<boolean>;
    ensureProject(projectPath: string): Promise<void>;
    setRunId(runId: string): void;
    ensureAgentRegistered(roleHint: string): Promise<string | null>;
    sendMessage(to: string, subject: string, body: string): Promise<void>;
    fetchInbox(agent: string, options?: {
        limit?: number;
    }): Promise<AgentMailMessage[]>;
    acknowledgeMessage(_agent: string, messageId: number): Promise<void>;
    reserveFiles(_paths: string[], _agentName: string, _leaseSecs?: number): Promise<void>;
    releaseFiles(_paths: string[], _agentName: string): Promise<void>;
}
//# sourceMappingURL=postgres-mail-client.d.ts.map