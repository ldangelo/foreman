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
import { ForemanStore, type Message } from "./store.js";
export type { Message };
export interface MailMessage {
    id: string;
    from: string;
    to: string;
    subject: string;
    body: string;
    read: boolean;
    createdAt: Date;
}
export declare class MailClient {
    private store;
    private runId;
    private agentType;
    /**
     * @param store - ForemanStore instance (shared with the worker)
     * @param runId - The run ID to scope messages to
     * @param agentType - This agent's role identifier (e.g. "developer", "qa")
     */
    constructor(store: ForemanStore, runId: string, agentType: string);
    /**
     * Send a message to another agent in the same run.
     * @param recipientAgentType - Target agent role (e.g. "qa", "developer", "lead")
     * @param subject - Short subject line describing the message purpose
     * @param body - Message body (free-form text or structured markdown)
     * @returns The sent MailMessage
     */
    send(recipientAgentType: string, subject: string, body: string): MailMessage;
    /**
     * Get all unread messages addressed to this agent.
     * Does NOT automatically mark them as read — call markRead() or markAllRead() after processing.
     */
    inbox(unreadOnly?: boolean): MailMessage[];
    /**
     * Get all messages addressed to this agent (including read ones).
     */
    allMessages(): MailMessage[];
    /**
     * Mark a specific message as read.
     */
    markRead(messageId: string): void;
    /**
     * Mark all messages addressed to this agent as read.
     */
    markAllRead(): void;
    /**
     * Soft-delete a message (it will no longer appear in inbox/allMessages).
     *
     * NOTE: This method is NOT scoped to the calling agent's own messages — any
     * agent that knows a message ID can soft-delete it, regardless of whether
     * they are the sender or recipient.  This is intentional for an internal
     * tooling system where all agents share the same trust boundary, but callers
     * should be aware that there is no ownership enforcement here.
     */
    delete(messageId: string): void;
    /**
     * Get all messages in the run (useful for Lead agent to see full thread).
     * Includes messages to/from all agent types.
     */
    allRunMessages(): MailMessage[];
    /**
     * Convenience: returns a formatted string summarising unread messages.
     * Useful for injecting into an agent's context prompt.
     */
    formatInbox(): string;
}
//# sourceMappingURL=mail.d.ts.map