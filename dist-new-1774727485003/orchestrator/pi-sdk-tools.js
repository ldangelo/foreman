/**
 * pi-sdk-tools.ts — Custom Pi SDK tool definitions for Foreman agents.
 *
 * Registers tools that agents can call natively (as structured tool calls)
 * instead of relying on prompt-based skills like `/send-mail`.
 */
import { Type } from "@mariozechner/pi-ai";
// ── send-mail tool ──────────────────────────────────────────────────────
const SendMailParams = Type.Object({
    to: Type.String({ description: "Recipient name (e.g. 'foreman')" }),
    subject: Type.String({ description: "Mail subject (e.g. 'agent-error')" }),
    body: Type.String({ description: "Mail body — JSON string or plain text" }),
});
/**
 * Create a send-mail ToolDefinition that uses the given SqliteMailClient.
 *
 * The agent calls this tool with { to, subject, body } and the mail is
 * sent directly via the SQLite mail client — no bash command, no skill
 * expansion, no prompt interpretation required.
 */
export function createSendMailTool(mailClient, _agentRole) {
    return {
        name: "send_mail",
        label: "Send Mail",
        description: "Send an Agent Mail message to another agent or to foreman. Use this to report errors only. Do NOT send phase-started or phase-complete — the executor handles those automatically.",
        promptSnippet: "Send error reports to foreman",
        promptGuidelines: [
            "Send an 'agent-error' mail if you encounter a fatal error",
        ],
        parameters: SendMailParams,
        async execute(_toolCallId, params) {
            try {
                await mailClient.sendMessage(params.to, params.subject, params.body);
                return {
                    content: [{ type: "text", text: `Mail sent to ${params.to}: ${params.subject}` }],
                    details: undefined,
                };
            }
            catch (err) {
                const msg = err instanceof Error ? err.message : String(err);
                return {
                    content: [{ type: "text", text: `Failed to send mail: ${msg}` }],
                    details: undefined,
                };
            }
        },
    };
}
//# sourceMappingURL=pi-sdk-tools.js.map