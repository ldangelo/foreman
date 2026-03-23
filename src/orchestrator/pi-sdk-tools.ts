/**
 * pi-sdk-tools.ts — Custom Pi SDK tool definitions for Foreman agents.
 *
 * Registers tools that agents can call natively (as structured tool calls)
 * instead of relying on prompt-based skills like `/send-mail`.
 */

import { Type, type Static } from "@mariozechner/pi-ai";
import type { ToolDefinition } from "@mariozechner/pi-coding-agent";
import { SqliteMailClient } from "../lib/sqlite-mail-client.js";

// ── send-mail tool ──────────────────────────────────────────────────────

const SendMailParams = Type.Object({
  to: Type.String({ description: "Recipient name (e.g. 'foreman')" }),
  subject: Type.String({ description: "Mail subject (e.g. 'phase-started', 'phase-complete', 'agent-error')" }),
  body: Type.String({ description: "Mail body — JSON string or plain text" }),
});

/**
 * Create a send-mail ToolDefinition that uses the given SqliteMailClient.
 *
 * The agent calls this tool with { to, subject, body } and the mail is
 * sent directly via the SQLite mail client — no bash command, no skill
 * expansion, no prompt interpretation required.
 */
export function createSendMailTool(
  mailClient: SqliteMailClient,
  _agentRole: string,
): ToolDefinition {
  return {
    name: "send_mail",
    label: "Send Mail",
    description: "Send an Agent Mail message to another agent or to foreman. Use this to report phase-started, phase-complete, and agent-error lifecycle events.",
    promptSnippet: "Send Agent Mail messages for lifecycle reporting (phase-started, phase-complete, agent-error)",
    promptGuidelines: [
      "Send a 'phase-started' mail at the beginning of your phase",
      "Send a 'phase-complete' mail when your phase succeeds",
      "Send an 'agent-error' mail if you encounter a fatal error",
    ],
    parameters: SendMailParams,
    async execute(
      _toolCallId: string,
      params: Static<typeof SendMailParams>,
    ) {
      try {
        await mailClient.sendMessage(params.to, params.subject, params.body);
        return {
          content: [{ type: "text" as const, text: `Mail sent to ${params.to}: ${params.subject}` }],
          details: undefined,
        };
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        return {
          content: [{ type: "text" as const, text: `Failed to send mail: ${msg}` }],
          details: undefined,
        };
      }
    },
  } as ToolDefinition;
}
