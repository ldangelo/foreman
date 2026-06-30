/**
 * `foreman inbox` — View the Postgres message inbox for agents in a pipeline run.
 *
 * Options:
 *   --agent <name>   Filter to a specific agent/role (default: show all)
 *   --run <id>       Filter to a specific run ID (default: latest run)
 *   --watch          Poll every 2s for new messages, show only new ones
 *   --unread         Show only unread messages
 *   --limit <n>      Max messages to show (default: 50)
 *   --ack            Mark shown messages as read
 */
import { Command } from "commander";
import type { Message } from "../../lib/store.js";
import { createTrpcClient } from "../../lib/trpc-client.js";
import { ElixirServerClient } from "../../lib/elixir-server-client.js";
type InboxClientContext = {
    backend: "node";
    client: ReturnType<typeof createTrpcClient>;
    projectId: string;
} | {
    backend: "elixir";
    client: ElixirServerClient;
    projectId: string;
};
interface PipelineEvent {
    id: string;
    runId: string | null;
    eventType: string;
    details: Record<string, unknown> | null;
    createdAt: string;
}
export declare function formatPipelineEvent(event: PipelineEvent): string;
export declare function formatEventSummary(eventType: string, details: Record<string, unknown> | null): string;
export declare function adaptPostgresEvent(row: {
    id: string;
    run_id: string | null;
    event_type: string;
    payload: unknown;
    created_at: string | Date;
}): PipelineEvent;
/**
 * Get the terminal width for output wrapping.
 * Falls back to 80 columns when stdout is not a TTY.
 */
export declare function getTerminalWidth(): number;
/**
 * Wrap text to fit within a maximum width, breaking at word boundaries.
 * Preserves existing newlines and indents continuation lines.
 */
export declare function wrapText(text: string, maxWidth: number): string;
declare function formatMessage(msg: Message, fullPayload?: boolean): string;
export interface TableRow {
    date: string;
    ticket: string;
    sender: string;
    receiver: string;
    kind: string | undefined;
    tool: string | undefined;
    args: string | undefined;
    runId: string;
    isRead: boolean;
}
interface ParsedMessageBody {
    phase?: string;
    status?: string;
    error?: string;
    currentPhase?: string;
    seedId?: string;
    runId?: string;
    message?: string;
    kind?: string;
    tool?: string;
    args?: string;
    argsPreview?: string;
    traceFile?: string;
    commandHonored?: boolean;
    verdict?: string;
    body?: string;
}
/**
 * Parse the message body JSON, extracting structured fields when present.
 * Gracefully degrades on non-JSON or missing fields.
 */
export declare function parseMessageBody(body: string): ParsedMessageBody;
/**
 * Truncate a string to maxLen characters, appending "…" if truncated.
 */
export declare function truncate(str: string, maxLen: number): string;
/**
 * Format a message as a table row.
 * @param msg The message to format
 * @param argsMaxLen Maximum length for the args column (default: 40)
 */
export declare function formatMessageTable(msg: Message, argsMaxLen?: number): TableRow;
/**
 * Render an array of table rows as a formatted ASCII table.
 * @param rows TableRow[] to render
 * @param argsWidth override for the args column width (default 40)
 */
export declare function renderMessageTable(rows: TableRow[], argsWidth?: number): string;
/**
 * Extract structured fields from a JSON message body for the newer table view.
 * Returns nulls for missing fields and falls back through
 * argsPreview → message → body for ARGS.
 */
export declare function extractBodyFields(body: string): {
    kind: string | null;
    tool: string | null;
    args: string | null;
};
interface TableColumns {
    datetime: string;
    ticket: string;
    sender: string;
    receiver: string;
    kind: string;
    tool: string;
    args: string;
}
interface FormattedRow {
    columns: TableColumns;
    raw: Message;
}
/**
 * Formats inbox messages as a space-aligned table with columns:
 * DATETIME | TICKET | SENDER | RECEIVER | KIND | TOOL | ARGS
 */
export declare class TableFormatter {
    private readonly terminalWidth;
    constructor({ terminalWidth }: {
        terminalWidth: number;
    });
    private formatDatetime;
    private middleCutTicket;
    formatRow(msg: Message): FormattedRow;
    calcWidths(messages: Message[]): {
        datetime: number;
        ticket: number;
        sender: number;
        receiver: number;
        kind: number;
        tool: number;
        args: number;
    };
    formatHeader(): string;
    private formatSeparator;
    private formatRowLine;
    formatTable(messages: Message[]): string;
}
export declare function resolveDaemonInboxContext(projectPath: string, projectSelector?: string): Promise<InboxClientContext | null>;
export declare function selectRecentMessages(messages: Message[], limit: number): Message[];
export { formatMessage };
export declare const inboxCommand: Command;
//# sourceMappingURL=inbox.d.ts.map