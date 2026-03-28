/**
 * SqliteMailClient — SQLite-backed drop-in replacement for AgentMailClient.
 *
 * Stores inter-agent messages in the existing ForemanStore messages table
 * instead of an external HTTP server. Messages are scoped by run_id.
 *
 * Implements the same duck-type interface as AgentMailClient so it can be
 * swapped in transparently in agent-worker.ts.
 */
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
export declare class SqliteMailClient {
    /** The registered agent name for this instance. Used as sender for outgoing messages. */
    agentName: string | null;
    private store;
    private runId;
    private projectPath;
    /**
     * Always returns true — SQLite is always available.
     */
    healthCheck(): Promise<boolean>;
    /**
     * Initialize the store for the given project path.
     * Also stores the projectPath for later reference.
     * Must be called before sendMessage / fetchInbox.
     */
    ensureProject(projectPath: string): Promise<void>;
    /**
     * Set the run ID used to scope all messages.
     * Called from agent-worker after the run is created/known.
     */
    setRunId(runId: string): void;
    /**
     * Returns roleHint as-is — no server-side name generation needed.
     * Also sets agentName to roleHint if not already set.
     */
    ensureAgentRegistered(roleHint: string): Promise<string | null>;
    /**
     * Send a message to another agent role.
     * Silently no-ops if runId or store is not initialized.
     */
    sendMessage(to: string, subject: string, body: string): Promise<void>;
    /**
     * Fetch unread messages for an agent.
     * Returns [] if not initialized or on any error.
     */
    fetchInbox(agent: string, options?: {
        limit?: number;
    }): Promise<AgentMailMessage[]>;
    /**
     * Mark a message as read by its ID.
     * Silent failure.
     */
    acknowledgeMessage(_agent: string, messageId: number): Promise<void>;
    /** No-op — file reservation is handled externally. */
    reserveFiles(_paths: string[], _agentName: string, _leaseSecs?: number): Promise<void>;
    /** No-op — file reservation is handled externally. */
    releaseFiles(_paths: string[], _agentName: string): Promise<void>;
}
//# sourceMappingURL=sqlite-mail-client.d.ts.map