/**
 * MailClient — High-level inter-agent messaging API
 *
 * Wraps ForemanStore messaging methods to provide a convenient, agent-scoped
 * interface for sending and receiving messages between agents in a pipeline run.
 *
 * Usage in an agent worker:
 *
 *   const mail = new MailClient(store, runId, "developer");
 *   mail.send("qa", "Tests failing", "Please see the error output:\n...");
 *   const inbox = mail.inbox();          // all unread messages
 *   mail.markAllRead();                  // mark everything read after processing
 */
/** Convert a raw store Message to the friendlier MailMessage shape. */
function toMailMessage(raw) {
    return {
        id: raw.id,
        from: raw.sender_agent_type,
        to: raw.recipient_agent_type,
        subject: raw.subject,
        body: raw.body,
        read: raw.read === 1,
        createdAt: new Date(raw.created_at),
    };
}
export class MailClient {
    store;
    runId;
    agentType;
    /**
     * @param store - ForemanStore instance (shared with the worker)
     * @param runId - The run ID to scope messages to
     * @param agentType - This agent's role identifier (e.g. "developer", "qa")
     */
    constructor(store, runId, agentType) {
        this.store = store;
        this.runId = runId;
        this.agentType = agentType;
    }
    /**
     * Send a message to another agent in the same run.
     * @param recipientAgentType - Target agent role (e.g. "qa", "developer", "lead")
     * @param subject - Short subject line describing the message purpose
     * @param body - Message body (free-form text or structured markdown)
     * @returns The sent MailMessage
     */
    send(recipientAgentType, subject, body) {
        const raw = this.store.sendMessage(this.runId, this.agentType, recipientAgentType, subject, body);
        return toMailMessage(raw);
    }
    /**
     * Get all unread messages addressed to this agent.
     * Does NOT automatically mark them as read — call markRead() or markAllRead() after processing.
     */
    inbox(unreadOnly = true) {
        return this.store
            .getMessages(this.runId, this.agentType, unreadOnly)
            .map(toMailMessage);
    }
    /**
     * Get all messages addressed to this agent (including read ones).
     */
    allMessages() {
        return this.store
            .getMessages(this.runId, this.agentType, false)
            .map(toMailMessage);
    }
    /**
     * Mark a specific message as read.
     */
    markRead(messageId) {
        this.store.markMessageRead(messageId);
    }
    /**
     * Mark all messages addressed to this agent as read.
     */
    markAllRead() {
        this.store.markAllMessagesRead(this.runId, this.agentType);
    }
    /**
     * Soft-delete a message (it will no longer appear in inbox/allMessages).
     *
     * NOTE: This method is NOT scoped to the calling agent's own messages — any
     * agent that knows a message ID can soft-delete it, regardless of whether
     * they are the sender or recipient.  This is intentional for an internal
     * tooling system where all agents share the same trust boundary, but callers
     * should be aware that there is no ownership enforcement here.
     */
    delete(messageId) {
        this.store.deleteMessage(messageId);
    }
    /**
     * Get all messages in the run (useful for Lead agent to see full thread).
     * Includes messages to/from all agent types.
     */
    allRunMessages() {
        return this.store.getAllMessages(this.runId).map(toMailMessage);
    }
    /**
     * Convenience: returns a formatted string summarising unread messages.
     * Useful for injecting into an agent's context prompt.
     */
    formatInbox() {
        const messages = this.inbox(true);
        if (messages.length === 0)
            return "(no unread messages)";
        return messages
            .map((m, i) => `[${i + 1}] From: ${m.from}\nSubject: ${m.subject}\n${m.body}`)
            .join("\n\n---\n\n");
    }
}
//# sourceMappingURL=mail.js.map