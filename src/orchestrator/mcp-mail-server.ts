/**
 * MCP Agent Mail Server
 *
 * An in-process MCP server providing a mailbox system for inter-agent communication.
 * Each pipeline phase (explorer, developer, qa, reviewer) gets its own inbox.
 *
 * Agents can use two tools:
 *   - send_message: Send a message to another agent's inbox
 *   - read_messages: Read messages from your own inbox
 *
 * The server is created once per pipeline run and shared across all phases,
 * so messages sent by Explorer are readable by Developer, etc.
 *
 * Usage:
 *   const mail = createMailServer();
 *   // Pass mail.mcpConfig to query() options:
 *   mcpServers: { "agent-mail": mail.mcpConfig }
 */

import { createSdkMcpServer, tool } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";

// ── Types ────────────────────────────────────────────────────────────────────

/** A single mail message stored in an agent's inbox. */
export interface MailMessage {
  from: string;
  to: string;
  subject: string;
  body: string;
  timestamp: string;
  id: number;
}

/** Result from sending a message. */
export interface SendResult {
  success: boolean;
  messageId?: number;
  error?: string;
}

/** Result from reading messages. */
export interface ReadResult {
  messages: MailMessage[];
  formatted: string;
}

/** Return value from createMailServer(). */
export interface MailServerHandle {
  /** Pass this to query() options as `mcpServers: { "agent-mail": mail.mcpConfig }` */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  mcpConfig: any;
  /** Read all messages in the given role's inbox. */
  getMessages(role: string): MailMessage[];
  /** Get a snapshot of all mailboxes (for debugging/logging). */
  getAllMessages(): Record<string, MailMessage[]>;
  /** Clear all messages (useful between pipeline retries). */
  clearAll(): void;
  /**
   * Exposed for testing: directly send a message without going through MCP transport.
   * Useful in unit tests where MCP transport is unavailable.
   */
  _sendMessage(args: { to: string; from: string; subject: string; body: string }): SendResult;
  /**
   * Exposed for testing: directly read messages for a role.
   */
  _readMessages(args: { role: string }): ReadResult;
}

// ── Validation ────────────────────────────────────────────────────────────────

/** Valid agent roles that can receive mail. */
export const MAIL_ROLES = ["explorer", "developer", "qa", "reviewer"] as const;
export type MailRole = (typeof MAIL_ROLES)[number];

// ── Implementation ────────────────────────────────────────────────────────────

/**
 * Create an in-process MCP mail server for inter-agent communication.
 *
 * Returns a handle with the MCP server config (to pass to SDK query options)
 * and helper methods to inspect/clear messages from the orchestrator side.
 */
export function createMailServer(): MailServerHandle {
  // In-memory message store: role → messages[]
  const mailboxes = new Map<string, MailMessage[]>();
  let nextId = 1;

  const getInbox = (role: string): MailMessage[] => {
    if (!mailboxes.has(role)) {
      mailboxes.set(role, []);
    }
    return mailboxes.get(role)!;
  };

  // ── Core business logic (also exposed for testing) ────────────────────

  function sendMessage(args: {
    to: string;
    from: string;
    subject: string;
    body: string;
  }): SendResult {
    if (!MAIL_ROLES.includes(args.to as MailRole)) {
      return {
        success: false,
        error: `Unknown role '${args.to}'. Valid roles: ${MAIL_ROLES.join(", ")}`,
      };
    }

    const message: MailMessage = {
      id: nextId++,
      from: args.from,
      to: args.to,
      subject: args.subject,
      body: args.body,
      timestamp: new Date().toISOString(),
    };

    getInbox(args.to).push(message);
    return { success: true, messageId: message.id };
  }

  function readMessages(args: { role: string }): ReadResult {
    const messages = getInbox(args.role);

    if (messages.length === 0) {
      return {
        messages: [],
        formatted: `No messages in ${args.role} inbox.`,
      };
    }

    const formatted =
      `${messages.length} message(s) in ${args.role} inbox:\n\n` +
      messages
        .map(
          (m) =>
            `--- Message #${m.id} ---\nFrom: ${m.from}\nSubject: ${m.subject}\nTime: ${m.timestamp}\n\n${m.body}`,
        )
        .join("\n\n");

    return { messages: [...messages], formatted };
  }

  // ── MCP tool definitions ──────────────────────────────────────────────

  const sendMessageTool = tool(
    "send_message",
    [
      "Send a message to another agent's inbox.",
      "Use this to communicate status updates, questions, or findings to other pipeline phases.",
      `Valid roles: ${MAIL_ROLES.join(", ")}.`,
    ].join(" "),
    {
      to: z.string().describe(
        `Recipient agent role: ${MAIL_ROLES.map((r) => `'${r}'`).join(", ")}`,
      ),
      from: z.string().describe("Your agent role (e.g., 'qa', 'reviewer')"),
      subject: z.string().describe("Brief subject line for the message"),
      body: z.string().describe("Full message content. Be specific and actionable."),
    },
    async (args) => {
      const result = sendMessage(args);
      if (!result.success) {
        return {
          content: [{ type: "text" as const, text: `Error: ${result.error}` }],
          isError: true,
        };
      }
      return {
        content: [
          {
            type: "text" as const,
            text: `Message #${result.messageId} sent to ${args.to} inbox.\nSubject: ${args.subject}`,
          },
        ],
      };
    },
  ) as unknown as ReturnType<typeof tool>;

  const readMessagesTool = tool(
    "read_messages",
    [
      "Read messages from your inbox.",
      "Check this at the start of your phase to see if other agents have sent you information.",
      "Messages are ordered oldest-first.",
    ].join(" "),
    {
      role: z.string().describe(
        `Your agent role to read messages for: ${MAIL_ROLES.map((r) => `'${r}'`).join(", ")}`,
      ),
    },
    async (args) => {
      const result = readMessages(args);
      return {
        content: [{ type: "text" as const, text: result.formatted }],
      };
    },
  ) as unknown as ReturnType<typeof tool>;

  // ── Create the MCP server ─────────────────────────────────────────────

  const mcpConfig = createSdkMcpServer({
    name: "agent-mail",
    version: "1.0.0",
    tools: [sendMessageTool, readMessagesTool],
  });

  return {
    mcpConfig,

    getMessages(role: string): MailMessage[] {
      return [...(mailboxes.get(role) ?? [])];
    },

    getAllMessages(): Record<string, MailMessage[]> {
      const result: Record<string, MailMessage[]> = {};
      for (const [role, messages] of mailboxes.entries()) {
        result[role] = [...messages];
      }
      return result;
    },

    clearAll(): void {
      mailboxes.clear();
      nextId = 1;
    },

    _sendMessage: sendMessage,
    _readMessages: readMessages,
  };
}
