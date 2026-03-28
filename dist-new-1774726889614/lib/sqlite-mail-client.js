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
export class SqliteMailClient {
    /** The registered agent name for this instance. Used as sender for outgoing messages. */
    agentName = null;
    store = null;
    runId = null;
    projectPath = null;
    // ── Lifecycle ────────────────────────────────────────────────────────────────
    /**
     * Always returns true — SQLite is always available.
     */
    async healthCheck() {
        return true;
    }
    /**
     * Initialize the store for the given project path.
     * Also stores the projectPath for later reference.
     * Must be called before sendMessage / fetchInbox.
     */
    async ensureProject(projectPath) {
        this.projectPath = projectPath;
        this.store = ForemanStore.forProject(projectPath);
    }
    /**
     * Set the run ID used to scope all messages.
     * Called from agent-worker after the run is created/known.
     */
    setRunId(runId) {
        this.runId = runId;
    }
    /**
     * Returns roleHint as-is — no server-side name generation needed.
     * Also sets agentName to roleHint if not already set.
     */
    async ensureAgentRegistered(roleHint) {
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
    async sendMessage(to, subject, body) {
        if (!this.store || !this.runId) {
            return;
        }
        try {
            this.store.sendMessage(this.runId, this.agentName ?? "foreman", to, subject, body);
        }
        catch {
            // Silent failure — messaging is non-critical infrastructure
        }
    }
    /**
     * Fetch unread messages for an agent.
     * Returns [] if not initialized or on any error.
     */
    async fetchInbox(agent, options) {
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
        }
        catch {
            return [];
        }
    }
    /**
     * Mark a message as read by its ID.
     * Silent failure.
     */
    async acknowledgeMessage(_agent, messageId) {
        if (!this.store)
            return;
        try {
            this.store.markMessageRead(String(messageId));
        }
        catch {
            // Silent failure
        }
    }
    // ── File reservation no-ops ──────────────────────────────────────────────────
    /** No-op — file reservation is handled externally. */
    async reserveFiles(_paths, _agentName, _leaseSecs) {
        // No-op for SQLite backend
    }
    /** No-op — file reservation is handled externally. */
    async releaseFiles(_paths, _agentName) {
        // No-op for SQLite backend
    }
}
//# sourceMappingURL=sqlite-mail-client.js.map