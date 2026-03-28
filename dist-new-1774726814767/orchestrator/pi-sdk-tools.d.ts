/**
 * pi-sdk-tools.ts — Custom Pi SDK tool definitions for Foreman agents.
 *
 * Registers tools that agents can call natively (as structured tool calls)
 * instead of relying on prompt-based skills like `/send-mail`.
 */
import type { ToolDefinition } from "@mariozechner/pi-coding-agent";
import { SqliteMailClient } from "../lib/sqlite-mail-client.js";
/**
 * Create a send-mail ToolDefinition that uses the given SqliteMailClient.
 *
 * The agent calls this tool with { to, subject, body } and the mail is
 * sent directly via the SQLite mail client — no bash command, no skill
 * expansion, no prompt interpretation required.
 */
export declare function createSendMailTool(mailClient: SqliteMailClient, _agentRole: string): ToolDefinition;
//# sourceMappingURL=pi-sdk-tools.d.ts.map