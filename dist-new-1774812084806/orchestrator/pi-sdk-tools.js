/**
 * pi-sdk-tools.ts — Custom Pi SDK tool definitions for Foreman agents.
 *
 * Registers tools that agents can call natively (as structured tool calls)
 * instead of relying on prompt-based skills like `/send-mail`.
 */
import { Type } from "@mariozechner/pi-ai";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
const execFileAsync = promisify(execFile);
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
// ── get-run-status tool ─────────────────────────────────────────────────
const GetRunStatusParams = Type.Object({
    runId: Type.String({ description: "The run ID to look up" }),
});
/**
 * Create a get_run_status ToolDefinition that reads run state from the store.
 *
 * Used by the troubleshooter agent to understand why a run failed and what
 * phase it was in when it stopped making progress.
 */
export function createGetRunStatusTool(store) {
    return {
        name: "get_run_status",
        label: "Get Run Status",
        description: "Read the current status and progress of a pipeline run. Returns phase, cost, turns, and the reason it failed (if applicable).",
        promptSnippet: "Read run status from the database",
        promptGuidelines: [
            "Call get_run_status at the start of a troubleshooter session to understand the run's current state",
        ],
        parameters: GetRunStatusParams,
        async execute(_toolCallId, params) {
            try {
                const run = store.getRun(params.runId);
                if (!run) {
                    return {
                        content: [{ type: "text", text: `Run ${params.runId} not found` }],
                        details: undefined,
                    };
                }
                const progress = store.getRunProgress(params.runId);
                const info = {
                    runId: run.id,
                    seedId: run.seed_id,
                    status: run.status,
                    startedAt: run.started_at,
                    completedAt: run.completed_at,
                    worktreePath: run.worktree_path,
                    currentPhase: progress?.currentPhase ?? null,
                    lastActivity: progress?.lastActivity ?? null,
                    costUsd: progress?.costUsd ?? 0,
                    turns: progress?.turns ?? 0,
                    toolCalls: progress?.toolCalls ?? 0,
                };
                return {
                    content: [{ type: "text", text: JSON.stringify(info, null, 2) }],
                    details: undefined,
                };
            }
            catch (err) {
                const msg = err instanceof Error ? err.message : String(err);
                return {
                    content: [{ type: "text", text: `Failed to get run status: ${msg}` }],
                    details: undefined,
                };
            }
        },
    };
}
// ── close-bead tool ─────────────────────────────────────────────────────
const CloseBeadParams = Type.Object({
    seedId: Type.String({ description: "The seed/bead ID to close (e.g. 'bd-abc')" }),
    reason: Type.String({ description: "Brief reason for closing (e.g. 'Work already merged into dev')" }),
});
/**
 * Create a close_bead ToolDefinition that runs `br close <seedId>`.
 *
 * Used by the troubleshooter agent to mark a bead complete when the work has
 * been confirmed as done (e.g. already merged into the target branch).
 */
export function createCloseBeadTool(projectPath) {
    return {
        name: "close_bead",
        label: "Close Bead",
        description: "Mark a bead/seed as complete using the br CLI. Only call this when you have confirmed the work is done and merged.",
        promptSnippet: "Close a completed bead using br",
        promptGuidelines: [
            "Only close a bead when the work is confirmed complete and merged into the target branch",
        ],
        parameters: CloseBeadParams,
        async execute(_toolCallId, params) {
            try {
                const brBin = process.env["BR_BIN"] ?? "br";
                const { stdout } = await execFileAsync(brBin, ["close", params.seedId, "--reason", params.reason], { cwd: projectPath });
                return {
                    content: [{ type: "text", text: `Bead ${params.seedId} closed: ${stdout.trim()}` }],
                    details: undefined,
                };
            }
            catch (err) {
                const msg = err instanceof Error ? err.message : String(err);
                return {
                    content: [{ type: "text", text: `Failed to close bead ${params.seedId}: ${msg}` }],
                    details: undefined,
                };
            }
        },
    };
}
//# sourceMappingURL=pi-sdk-tools.js.map