/**
 * pi-sdk-tools.ts — Custom Pi SDK tool definitions for Foreman agents.
 *
 * Registers tools that agents can call natively (as structured tool calls)
 * instead of relying on prompt-based skills like `/send-mail`.
 */
import type { ToolDefinition } from "@mariozechner/pi-coding-agent";
import type { AgentMailClient } from "../lib/agent-mail-client.js";
import type { ForemanStore } from "../lib/store.js";
export type RunStatusReader = Pick<ForemanStore, "getRun" | "getRunProgress">;
/**
 * Create a send-mail ToolDefinition that uses the given NullAgentMailClient.
 *
 * The agent calls this tool with { to, subject, body } and the mail is
 * sent directly via the configured mail client — no bash command, no skill
 * expansion, no prompt interpretation required.
 */
export declare function createSendMailTool(mailClient: AgentMailClient, _agentRole: string): ToolDefinition;
/**
 * Create a get_run_status ToolDefinition that reads run state from the store.
 *
 * Used by the troubleshooter agent to understand why a run failed and what
 * phase it was in when it stopped making progress.
 */
export declare function createGetRunStatusTool(store: RunStatusReader): ToolDefinition;
/**
 * Create a close_bead ToolDefinition that runs `br close <beadId>`.
 *
 * Used by the troubleshooter agent to mark a bead complete when the work has
 * been confirmed as done (e.g. already merged into the target branch).
 */
export declare function createCloseBeadTool(projectPath: string): ToolDefinition;
//# sourceMappingURL=pi-sdk-tools.d.ts.map