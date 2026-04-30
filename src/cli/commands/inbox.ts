/**
 * `foreman inbox` — View the SQLite message inbox for agents in a pipeline run.
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
import chalk from "chalk";
import { resolve } from "node:path";
import { ForemanStore } from "../../lib/store.js";
import type { Message, Run } from "../../lib/store.js";
import { createTrpcClient } from "../../lib/trpc-client.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import { listRegisteredProjects, resolveRepoRootProjectPath, requireProjectOrAllInMultiMode } from "./project-task-support.js";

interface DaemonMailMessage {
  id: string;
  run_id: string;
  sender_agent_type: string;
  recipient_agent_type: string;
  subject: string;
  body: string;
  read: number;
  created_at: string;
  deleted_at: string | null;
}

interface DaemonRunRow {
  id: string;
  bead_id: string;
  status: string;
  branch: string;
  queued_at: string;
  started_at: string | null;
  finished_at: string | null;
  created_at: string;
}

// ── Formatting helpers ────────────────────────────────────────────────────────

/**
 * Get the terminal width for output wrapping.
 * Falls back to 80 columns when stdout is not a TTY.
 */
export function getTerminalWidth(): number {
  return process.stdout.columns || 80;
}

/**
 * Wrap text to fit within a maximum width, breaking at word boundaries.
 * Preserves existing newlines and indents continuation lines.
 */
export function wrapText(text: string, maxWidth: number): string {
  const lines = text.split("\n");
  return lines
    .map((line) => {
      if (line.length <= maxWidth) return line;
      // Word wrap: break at maxWidth, then continue at indent
      let result = "";
      let remaining = line;
      while (remaining.length > maxWidth) {
        // Find last space before maxWidth
        const slice = remaining.slice(0, maxWidth);
        const lastSpace = slice.lastIndexOf(" ");
        if (lastSpace > 0) {
          result += slice.slice(0, lastSpace) + "\n";
          remaining = remaining.slice(lastSpace + 1);
        } else {
          // No space found, force break
          result += slice + "\n";
          remaining = remaining.slice(maxWidth);
        }
      }
      return result + remaining;
    })
    .join("\n");
}

function formatTimestamp(isoStr: string): string {
  try {
    const d = new Date(isoStr);
    const pad = (n: number): string => String(n).padStart(2, "0");
    return (
      `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
      `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`
    );
  } catch {
    return isoStr;
  }
}

function formatMessage(msg: Message, fullPayload = false): string {
  const ts = formatTimestamp(msg.created_at);
  const readMark = msg.read === 1 ? " [read]" : "";
  const header = `[${ts}] ${msg.sender_agent_type} → ${msg.recipient_agent_type}  |  ${msg.subject}${readMark}`;

  if (fullPayload) {
    // Show full body — try to pretty-print JSON, otherwise show raw
    let bodyDisplay: string;
    try {
      const parsed = JSON.parse(msg.body);
      bodyDisplay = JSON.stringify(parsed, null, 2);
    } catch {
      bodyDisplay = msg.body;
    }
    // Wrap at terminal width to prevent line clipping on long JSON payloads
    const terminalWidth = getTerminalWidth();
    const wrappedBody = wrapText(bodyDisplay, terminalWidth - 2); // -2 for indentation
    return `${header}\n${wrappedBody.split("\n").map((l) => `  ${l}`).join("\n")}`;
  }

  // Default: try to parse JSON and show key fields for readability
  let preview: string;
  try {
    const parsed = JSON.parse(msg.body) as Record<string, unknown>;
    const parts: string[] = [];
    if (typeof parsed["phase"] === "string") parts.push(`phase=${parsed["phase"]}`);
    if (typeof parsed["status"] === "string") parts.push(`status=${parsed["status"]}`);
    if (typeof parsed["error"] === "string") parts.push(`error=${parsed["error"]}`);
    if (typeof parsed["currentPhase"] === "string") parts.push(`currentPhase=${parsed["currentPhase"]}`);
    if (typeof parsed["seedId"] === "string") parts.push(`seedId=${parsed["seedId"]}`);
    if (typeof parsed["runId"] === "string") parts.push(`runId=${parsed["runId"]}`);
    if (typeof parsed["message"] === "string") parts.push(`message=${parsed["message"]}`);
    if (typeof parsed["kind"] === "string") parts.push(`kind=${parsed["kind"]}`);
    if (typeof parsed["tool"] === "string") parts.push(`tool=${parsed["tool"]}`);
    if (typeof parsed["argsPreview"] === "string") parts.push(`args=${parsed["argsPreview"]}`);
    if (typeof parsed["traceFile"] === "string") parts.push(`trace=${parsed["traceFile"]}`);
    if (typeof parsed["commandHonored"] === "boolean") parts.push(`commandHonored=${parsed["commandHonored"] ? "yes" : "no"}`);
    if (typeof parsed["verdict"] === "string") parts.push(`verdict=${parsed["verdict"]}`);
    if (parts.length > 0) {
      preview = parts.join(", ");
    } else {
      // No recognized fields — fall back to truncated raw body
      preview = msg.body.slice(0, 200).replace(/\n/g, " ");
      if (msg.body.length > 200) preview += "...";
    }
  } catch {
    // Not JSON — truncate with ellipsis
    preview = msg.body.slice(0, 200).replace(/\n/g, " ");
    if (msg.body.length > 200) preview += "...";
  }

  return `${header}\n  ${preview}`;
}

// ── Table row type ────────────────────────────────────────────────────────────

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

// ── Parsed message body ──────────────────────────────────────────────────────

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
export function parseMessageBody(body: string): ParsedMessageBody {
  if (!body) return {};
  try {
    const parsed = JSON.parse(body) as Record<string, unknown>;
    return {
      phase: typeof parsed["phase"] === "string" ? parsed["phase"] : undefined,
      status: typeof parsed["status"] === "string" ? parsed["status"] : undefined,
      error: typeof parsed["error"] === "string" ? parsed["error"] : undefined,
      currentPhase: typeof parsed["currentPhase"] === "string" ? parsed["currentPhase"] : undefined,
      seedId: typeof parsed["seedId"] === "string" ? parsed["seedId"] : undefined,
      runId: typeof parsed["runId"] === "string" ? parsed["runId"] : undefined,
      message: typeof parsed["message"] === "string" ? parsed["message"] : undefined,
      kind: typeof parsed["kind"] === "string" ? parsed["kind"] : undefined,
      tool: typeof parsed["tool"] === "string" ? parsed["tool"] : undefined,
      argsPreview: typeof parsed["argsPreview"] === "string" ? parsed["argsPreview"] : undefined,
      traceFile: typeof parsed["traceFile"] === "string" ? parsed["traceFile"] : undefined,
      commandHonored: typeof parsed["commandHonored"] === "boolean" ? parsed["commandHonored"] : undefined,
      verdict: typeof parsed["verdict"] === "string" ? parsed["verdict"] : undefined,
      body: typeof parsed["body"] === "string" ? parsed["body"] : undefined,
    };
  } catch {
    return {};
  }
}

/**
 * Truncate a string to maxLen characters, appending "…" if truncated.
 */
export function truncate(str: string, maxLen: number): string {
  if (maxLen <= 0) return "";
  if (str.length <= maxLen) return str;
  if (maxLen === 1) return "…";
  if (maxLen <= 3) return "…";

  const slice = str.slice(0, maxLen);
  const lastSpace = slice.lastIndexOf(" ");
  if (lastSpace >= maxLen - 4) {
    return str.slice(0, lastSpace) + "…";
  }

  return str.slice(0, maxLen - 1) + "…";
}

// ── Table formatting ───────────────────────────────────────────────────────────

const DEFAULT_ARGS_WIDTH = 40;

/**
 * Format a message as a table row.
 * @param msg The message to format
 * @param argsMaxLen Maximum length for the args column (default: 40)
 */
export function formatMessageTable(msg: Message, argsMaxLen = DEFAULT_ARGS_WIDTH): TableRow {
  const parsed = parseMessageBody(msg.body);
  return {
    date: formatTimestamp(msg.created_at),
    ticket: parsed.seedId ?? msg.run_id,
    sender: msg.sender_agent_type,
    receiver: msg.recipient_agent_type,
    kind: parsed.kind,
    tool: parsed.tool,
    args: parsed.argsPreview ? truncate(parsed.argsPreview, argsMaxLen) : undefined,
    runId: msg.run_id,
    isRead: msg.read === 1,
  };
}

// ── ASCII table renderer ───────────────────────────────────────────────────────

/**
 * Column widths for the inbox table.
 * Compact sortable datetime | ticket | sender | receiver | kind | tool | args
 */
const COL_WIDTHS = {
  date: 19,    // "2026-04-30 14:23:45"
  ticket: 20,
  sender: 12,
  receiver: 12,
  kind: 14,
  tool: 14,
} as const;
const ARGS_DEFAULT = 40;

interface ColumnSizes {
  date: number;
  ticket: number;
  sender: number;
  receiver: number;
  kind: number;
  tool: number;
  args: number;
}

/**
 * Render an array of table rows as a formatted ASCII table.
 * @param rows TableRow[] to render
 * @param argsWidth override for the args column width (default 40)
 */
export function renderMessageTable(rows: TableRow[], argsWidth = ARGS_DEFAULT): string {
  if (rows.length === 0) return "";

  const sizes: ColumnSizes = {
    date: COL_WIDTHS.date,
    ticket: Math.max(...rows.map((r) => r.ticket.length), COL_WIDTHS.ticket),
    sender: Math.max(...rows.map((r) => r.sender.length), COL_WIDTHS.sender),
    receiver: Math.max(...rows.map((r) => r.receiver.length), COL_WIDTHS.receiver),
    kind: Math.max(...rows.map((r) => r.kind?.length ?? 4), COL_WIDTHS.kind),
    tool: Math.max(...rows.map((r) => r.tool?.length ?? 4), COL_WIDTHS.tool),
    args: argsWidth,
  };

  const totalWidth =
    sizes.date + sizes.ticket + sizes.sender + sizes.receiver +
    sizes.kind + sizes.tool + sizes.args + 8;

  const hr = "─".repeat(totalWidth);

  const header = [
    pad("DATE", sizes.date),
    pad("TICKET", sizes.ticket),
    pad("SENDER", sizes.sender),
    pad("RECEIVER", sizes.receiver),
    pad("KIND", sizes.kind),
    pad("TOOL", sizes.tool),
    pad("ARGS", sizes.args),
  ].join(" │ ");

  const padCell = (val: string | undefined, width: number): string =>
    pad(val ?? "-", width);

  const tableLines = rows.map((row) =>
    [
      pad(row.date, sizes.date),
      pad(row.ticket, sizes.ticket),
      pad(row.sender, sizes.sender),
      pad(row.receiver, sizes.receiver),
      padCell(row.kind, sizes.kind),
      padCell(row.tool, sizes.tool),
      padCell(row.args, sizes.args),
    ].join(" │ ")
  );

  return [hr, header, hr, ...tableLines, hr].join("\n");
}

function pad(val: string, width: number): string {
  if (val.length > width) return val.slice(0, width - 1) + "…";
  return val.padEnd(width, " ");
}

// ── TableFormatter (tabular message view) ────────────────────────────────────

/**
 * Extract structured fields from a JSON message body for the newer table view.
 * Returns nulls for missing fields and falls back through
 * argsPreview → message → body for ARGS.
 */
export function extractBodyFields(body: string): {
  kind: string | null;
  tool: string | null;
  args: string | null;
} {
  const parsed = parseMessageBody(body);
  return {
    kind: parsed.kind ?? null,
    tool: parsed.tool ?? null,
    args: parsed.argsPreview ?? parsed.message ?? parsed.body ?? null,
  };
}

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
export class TableFormatter {
  private readonly terminalWidth: number;

  constructor({ terminalWidth }: { terminalWidth: number }) {
    this.terminalWidth = terminalWidth;
  }

  private formatDatetime(isoStr: string): string {
    return formatTimestamp(isoStr);
  }

  private middleCutTicket(id: string): string {
    const MAX = 20;
    if (id.length <= MAX) return id;
    const prefix = id.slice(0, 7);
    const suffix = id.slice(id.length - (MAX - 7 - 1));
    return `${prefix}…${suffix}`;
  }

  formatRow(msg: Message): FormattedRow {
    const { kind, tool, args } = extractBodyFields(msg.body);
    const dash = "—";
    const argsMax = 30;

    return {
      columns: {
        datetime: this.formatDatetime(msg.created_at),
        ticket: this.middleCutTicket(msg.run_id),
        sender: msg.sender_agent_type,
        receiver: msg.recipient_agent_type,
        kind: kind ?? dash,
        tool: tool ?? dash,
        args: truncate(args ?? dash, argsMax),
      },
      raw: msg,
    };
  }

  calcWidths(messages: Message[]): {
    datetime: number;
    ticket: number;
    sender: number;
    receiver: number;
    kind: number;
    tool: number;
    args: number;
  } {
    const rows = messages.map((m) => this.formatRow(m));
    const base = { datetime: 19, ticket: 8, sender: 8, receiver: 8, kind: 4, tool: 4, args: 4 };

    const computed = {
      datetime: Math.max(base.datetime, ...rows.map((r) => r.columns.datetime.length)),
      ticket: Math.max(base.ticket, ...rows.map((r) => r.columns.ticket.length)),
      sender: Math.max(base.sender, ...rows.map((r) => r.columns.sender.length)),
      receiver: Math.max(base.receiver, ...rows.map((r) => r.columns.receiver.length)),
      kind: Math.max(base.kind, ...rows.map((r) => r.columns.kind.length)),
      tool: Math.max(base.tool, ...rows.map((r) => r.columns.tool.length)),
      args: Math.max(base.args, ...rows.map((r) => r.columns.args.length)),
    };

    computed.ticket = Math.min(computed.ticket, 20);
    computed.datetime = 19;
    computed.sender = Math.min(Math.max(computed.sender, 8), 15);
    computed.receiver = Math.min(Math.max(computed.receiver, 8), 15);
    computed.kind = Math.min(computed.kind, 12);
    computed.tool = Math.min(computed.tool, 12);

    const fixed =
      computed.datetime +
      computed.ticket +
      computed.sender +
      computed.receiver +
      computed.kind +
      computed.tool +
      6;
    const available = this.terminalWidth - fixed;
    computed.args = Math.max(computed.args, Math.min(available, 80));

    return computed;
  }

  formatHeader(): string {
    return "DATETIME          TICKET       SENDER     RECEIVER   KIND       TOOL       ARGS";
  }

  private formatSeparator(widths: ReturnType<typeof this.calcWidths>): string {
    const { datetime, ticket, sender, receiver, kind, tool, args } = widths;
    return (
      `${"─".repeat(datetime)} ` +
      `${"─".repeat(ticket)} ` +
      `${"─".repeat(sender)} ` +
      `${"─".repeat(receiver)} ` +
      `${"─".repeat(kind)} ` +
      `${"─".repeat(tool)} ` +
      `${"─".repeat(args)}`
    );
  }

  private formatRowLine(
    row: FormattedRow,
    widths: ReturnType<typeof this.calcWidths>,
  ): string {
    const { datetime, ticket, sender, receiver, kind, tool, args } = widths;
    return (
      row.columns.datetime.padEnd(datetime) +
      " " +
      row.columns.ticket.padEnd(ticket) +
      " " +
      row.columns.sender.padEnd(sender) +
      " " +
      row.columns.receiver.padEnd(receiver) +
      " " +
      row.columns.kind.padEnd(kind) +
      " " +
      row.columns.tool.padEnd(tool) +
      " " +
      row.columns.args.padEnd(args)
    );
  }

  formatTable(messages: Message[]): string {
    if (messages.length === 0) {
      return this.formatHeader() + "\n";
    }

    const rows = messages.map((m) => this.formatRow(m));
    const widths = this.calcWidths(messages);

    return [
      this.formatHeader(),
      this.formatSeparator(widths),
      ...rows.map((r) => this.formatRowLine(r, widths)),
    ].join("\n") + "\n";
  }
}

// ── Run status formatting ─────────────────────────────────────────────────────

function formatRunStatus(run: Run): string {
  const ts = formatTimestamp(new Date().toISOString());
  let statusStr: string;
  if (run.status === "completed") {
    statusStr = chalk.green("COMPLETED");
  } else if (run.status === "failed") {
    statusStr = chalk.red("FAILED");
  } else if (run.status === "running") {
    statusStr = chalk.blue("RUNNING");
  } else {
    statusStr = chalk.yellow(run.status.toUpperCase());
  }
  return `[${ts}] ${chalk.bold("●")} ${run.seed_id} ${statusStr} (run ${run.id})`;
}

function adaptDaemonMessage(row: DaemonMailMessage): Message {
  return {
    id: row.id,
    run_id: row.run_id,
    sender_agent_type: row.sender_agent_type,
    recipient_agent_type: row.recipient_agent_type,
    subject: row.subject,
    body: row.body,
    read: row.read,
    created_at: row.created_at,
    deleted_at: row.deleted_at,
  };
}

function adaptDaemonRun(row: DaemonRunRow): Run {
  return {
    id: row.id,
    project_id: "",
    seed_id: row.bead_id,
    agent_type: "daemon",
    session_key: null,
    worktree_path: null,
    status: row.status as Run["status"],
    started_at: row.started_at,
    completed_at: row.finished_at,
    created_at: row.created_at,
    progress: null,
    base_branch: null,
  };
}

export async function resolveDaemonInboxContext(projectPath: string, projectSelector?: string): Promise<{
  client: ReturnType<typeof createTrpcClient>;
  projectId: string;
} | null> {
  try {
    const projects = await listRegisteredProjects();
    const project = projectSelector
      ? projects.find((record) => record.id === projectSelector || record.name === projectSelector)
      : projects.find((record) => resolve(record.path) === resolve(projectPath));
    if (!project) return null;
    return { client: createTrpcClient(), projectId: project.id };
  } catch {
    return null;
  }
}

async function resolveDaemonRunId(
  client: ReturnType<typeof createTrpcClient>,
  projectId: string,
  options: { run?: string; bead?: string },
): Promise<string | null> {
  if (options.run) return options.run;
  const runs = await client.runs.list({ projectId, limit: 100 }) as DaemonRunRow[];
  if (options.bead) {
    const match = runs.find((run) => run.bead_id === options.bead);
    return match?.id ?? null;
  }
  return runs[0]?.id ?? null;
}

async function fetchDaemonMessages(
  client: ReturnType<typeof createTrpcClient>,
  projectId: string,
  options: { all?: boolean; runId?: string; agent?: string; unread?: boolean; limit: number },
): Promise<Message[]> {
  if (options.all) {
    const rows = await client.mail.listGlobal({ projectId, limit: options.limit }) as DaemonMailMessage[];
    const filtered = options.agent
      ? rows.filter((row) => row.recipient_agent_type === options.agent)
      : rows;
    const unreadFiltered = options.unread ? filtered.filter((row) => row.read === 0) : filtered;
    return unreadFiltered.map(adaptDaemonMessage);
  }
  if (!options.runId) return [];
  const rows = await client.mail.list({
    projectId,
    runId: options.runId,
    agentType: options.agent,
    unreadOnly: options.unread,
  }) as DaemonMailMessage[];
  return rows.slice(0, options.limit).map(adaptDaemonMessage);
}

// ── Run resolution ────────────────────────────────────────────────────────────

function resolveLatestRunId(store: ForemanStore): string | null {
  // Get the most recently created run (any status)
  const runs = store.getRunsByStatuses(
    ["pending", "running", "completed", "failed", "stuck", "merged", "conflict", "test-failed", "pr-created", "reset"],
  );
  if (runs.length === 0) return null;
  // Runs are returned in DESC created_at order
  return runs[0]?.id ?? null;
}

function resolveRunIdBySeed(store: ForemanStore, seedId: string): string | null {
  const runs = store.getRunsByStatuses(
    ["pending", "running", "completed", "failed", "stuck", "merged", "conflict", "test-failed", "pr-created", "reset"],
  );
  const seedRuns = runs.filter((r) => r.seed_id === seedId);
  // Runs are returned DESC by created_at, so [0] is most recent
  return seedRuns[0]?.id ?? null;
}

// ── Main command ──────────────────────────────────────────────────────────────

// Exported for unit testing
export { formatMessage };

export const inboxCommand = new Command("inbox")
  .description("View the SQLite message inbox for agents in a pipeline run")
  .option("--agent <name>", "Filter to a specific agent/role (default: show all)")
  .option("--run <id>", "Filter to a specific run ID (default: latest run)")
  .option("--bead <id>", "Resolve run by bead ID (uses most recent run for that bead)")
  .option("--all", "Watch messages across all runs (ignores --run and --bead)")
  .option("--watch", "Poll every 2s for new messages (shows only new ones)")
  .option("--unread", "Show only unread messages")
  .option("--limit <n>", "Max messages to show", "50")
  .option("--ack", "Mark shown messages as read after displaying them")
  .option("--full", "Show full message payloads (no truncation, JSON pretty-printed)")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(async (options: {
    agent?: string;
    run?: string;
    bead?: string;
    all?: boolean;
    watch?: boolean;
    unread?: boolean;
    limit?: string;
    ack?: boolean;
    full?: boolean;
    project?: string;
    projectPath?: string;
  }) => {
    const fullPayload = options.full ?? false;
    const limit = parseInt(options.limit ?? "50", 10);

    // Require --project or --all in multi-project mode
    await requireProjectOrAllInMultiMode(options.project, options.all ?? false);

    // Resolve the project root via --project flag or VCS auto-detection
    let projectPath: string;
    try {
      projectPath = await resolveRepoRootProjectPath({
        project: options.project,
        projectPath: options.projectPath,
      });
    } catch {
      projectPath = process.cwd();
    }

    const daemon = await resolveDaemonInboxContext(projectPath, options.project);
    const store = daemon ? null : ForemanStore.forProject(projectPath);

    try {
      // ── One-shot global mode (--all without --watch) ───────────────────────
      if (options.all && !options.watch) {
        let messages = daemon
          ? await fetchDaemonMessages(daemon.client, daemon.projectId, { all: true, agent: options.agent, unread: options.unread, limit })
          : store!.getAllMessagesGlobal(limit);

        // Apply agent filter (by recipient, matching single-run behavior)
        if (!daemon && options.agent) {
          messages = messages.filter((m) => m.recipient_agent_type === options.agent);
        }

        // Apply unread filter
        if (!daemon && options.unread) {
          messages = messages.filter((m) => m.read === 0);
        }

        if (messages.length === 0) {
          console.log(`No ${options.unread ? "unread " : ""}messages found across all runs${options.agent ? ` (agent: ${options.agent})` : ""}.`);
        } else {
          if (fullPayload) {
            console.log(`\nInbox — all runs${options.agent ? `  agent: ${options.agent}` : ""}\n${"─".repeat(70)}`);
            for (const msg of messages) {
              console.log(formatMessage(msg, true));
              console.log("");
            }
            console.log(`${"─".repeat(70)}\n${messages.length} message(s) shown.`);
          } else {
            const rows = messages.map((msg) => formatMessageTable(msg));
            console.log(`\nInbox — all runs${options.agent ? `  agent: ${options.agent}` : ""}`);
            console.log(renderMessageTable(rows));
            console.log(`${messages.length} message(s) shown.`);
          }
        }

        if (options.ack && messages.length > 0) {
          if (daemon) {
            for (const msg of messages) {
              await daemon.client.mail.markRead({ projectId: daemon.projectId, messageId: msg.id });
            }
          } else {
            for (const msg of messages) {
              store!.markMessageRead(msg.id);
            }
          }
          console.log(`Marked ${messages.length} message(s) as read.`);
        }
        return;
      }

      // ── Global watch mode (--all --watch) ──────────────────────────────────
      if (options.all && options.watch) {
        console.log("Watching all runs... (Ctrl-C to stop)\n");
        const seenIds = new Set<string>();
        const seenRunIds = new Set<string>();
        const initialGlobal = daemon
          ? await fetchDaemonMessages(daemon.client, daemon.projectId, { all: true, agent: options.agent, unread: false, limit })
          : store!.getAllMessagesGlobal(limit);
        if (initialGlobal.length > 0) {
          console.log(`── past messages ${"─".repeat(53)}`);
          if (fullPayload) {
            for (const m of initialGlobal) { console.log(formatMessage(m, true)); console.log(""); seenIds.add(m.id); }
          } else {
            const rows = initialGlobal.map((m) => formatMessageTable(m));
            console.log(renderMessageTable(rows));
            console.log("");
            for (const m of initialGlobal) seenIds.add(m.id);
          }
          console.log(`── live ─────────────────────────────────────────────────────────────\n`);
        }
        const initRuns = daemon
          ? (await daemon.client.runs.list({ projectId: daemon.projectId, limit: 100 }) as DaemonRunRow[]).map(adaptDaemonRun)
          : store!.getRunsByStatuses(["completed", "failed", "running"]);
        for (const r of initRuns) seenRunIds.add(r.id);
        const pollAll = (): void => {
          void (async () => {
            const statusRuns = daemon
              ? (await daemon.client.runs.list({ projectId: daemon.projectId, limit: 100 }) as DaemonRunRow[]).map(adaptDaemonRun)
              : store!.getRunsByStatuses(["completed", "failed", "running"]);
            for (const run of statusRuns) {
              if (!seenRunIds.has(run.id)) { seenRunIds.add(run.id); console.log(formatRunStatus(run)); console.log(""); }
            }
            const msgs = daemon
              ? await fetchDaemonMessages(daemon.client, daemon.projectId, { all: true, agent: options.agent, unread: false, limit })
              : store!.getAllMessagesGlobal(limit);
            for (const msg of msgs.filter((m) => !seenIds.has(m.id))) {
              seenIds.add(msg.id);
              if (fullPayload) {
                console.log(formatMessage(msg, true));
                console.log("");
              } else {
                const rows = [formatMessageTable(msg)];
                console.log(renderMessageTable(rows));
                console.log("");
              }
            }
          })().catch(() => undefined);
        };
        pollAll();
        const interval = setInterval(pollAll, 2000);
        process.on("SIGINT", () => { clearInterval(interval); store?.close(); process.exit(0); });
        return;
      }

      const runId = daemon
        ? await resolveDaemonRunId(daemon.client, daemon.projectId, { run: options.run, bead: options.bead })
        : options.run
          ?? (options.bead ? resolveRunIdBySeed(store!, options.bead) : null)
          ?? resolveLatestRunId(store!);
      if (!runId) {
        console.error("No runs found. Start a pipeline first with `foreman run`.");
        process.exit(1);
      }

      // Resolve seed ID for display (run record carries seed_id)
      const allRuns = daemon
        ? (await daemon.client.runs.list({ projectId: daemon.projectId, limit: 100 }) as DaemonRunRow[]).map(adaptDaemonRun)
        : store!.getRunsByStatuses(
          ["pending", "running", "completed", "failed", "stuck", "merged", "conflict", "test-failed", "pr-created", "reset"],
        );
      const thisRun = allRuns.find((r) => r.id === runId);
      const seedLabel = thisRun?.seed_id ? `  bead: ${thisRun.seed_id}` : "";

      if (!options.watch) {
        // One-shot: show current run lifecycle status then fetch and display messages
        const runStatusRuns = daemon
          ? (await daemon.client.runs.list({ projectId: daemon.projectId, limit: 100 }) as DaemonRunRow[]).map(adaptDaemonRun)
          : store!.getRunsByStatuses(["completed", "failed"]);
        const currentRun = runStatusRuns.find((r) => r.id === runId);
        if (currentRun) {
          console.log(formatRunStatus(currentRun));
          console.log("");
        }

        const messages = daemon
          ? await fetchDaemonMessages(daemon.client, daemon.projectId, { runId, agent: options.agent, unread: options.unread, limit })
          : fetchMessages(store!, runId, options.agent, options.unread ?? false, limit);
        if (messages.length === 0) {
          console.log(`No ${options.unread ? "unread " : ""}messages for run ${runId}${seedLabel}${options.agent ? ` (agent: ${options.agent})` : ""}.`);
        } else {
          if (fullPayload) {
            console.log(`\nInbox — run: ${runId}${seedLabel}${options.agent ? `  agent: ${options.agent}` : ""}\n${"─".repeat(70)}`);
            for (const msg of messages) {
              console.log(formatMessage(msg, true));
              console.log("");
            }
            console.log(`${"─".repeat(70)}\n${messages.length} message(s) shown.`);
          } else {
            const rows = messages.map((msg) => formatMessageTable(msg));
            console.log(`\nInbox — run: ${runId}${seedLabel}${options.agent ? `  agent: ${options.agent}` : ""}`);
            console.log(renderMessageTable(rows));
            console.log(`${messages.length} message(s) shown.`);
          }
        }

        if (options.ack && messages.length > 0) {
          if (daemon) {
            for (const msg of messages) {
              await daemon.client.mail.markRead({ projectId: daemon.projectId, messageId: msg.id });
            }
          } else {
            for (const msg of messages) {
              store!.markMessageRead(msg.id);
            }
          }
          console.log(`Marked ${messages.length} message(s) as read.`);
        }
        return;
      }

      // Watch mode: poll every 2s, show past messages first then new ones
      console.log(`Watching inbox for run ${runId}${seedLabel}${options.agent ? ` (agent: ${options.agent})` : ""}... (Ctrl-C to stop)\n`);
      const seenIds = new Set<string>();
      const seenRunIds = new Set<string>();

      // Initial fetch — print existing messages immediately, then track them as seen
      const initial = daemon
        ? await fetchDaemonMessages(daemon.client, daemon.projectId, { runId, agent: options.agent, unread: false, limit })
        : fetchMessages(store!, runId, options.agent, false, limit);
      if (initial.length > 0) {
        console.log(`── past messages ${"─".repeat(53)}`);
        if (fullPayload) {
          for (const m of initial) { console.log(formatMessage(m, true)); console.log(""); seenIds.add(m.id); }
          console.log(`── live ─────────────────────────────────────────────────────────────\n`);
        } else {
          const rows = initial.map((m) => formatMessageTable(m));
          console.log(renderMessageTable(rows));
          console.log("");
          for (const m of initial) seenIds.add(m.id);
          console.log(`── live ─────────────────────────────────────────────────────────────\n`);
        }
      }

      // Seed seenRunIds with any already-completed/failed runs so we only show new transitions
      const initialRuns = daemon
        ? (await daemon.client.runs.list({ projectId: daemon.projectId, limit: 100 }) as DaemonRunRow[]).map(adaptDaemonRun)
        : store!.getRunsByStatuses(["completed", "failed"]);
      for (const r of initialRuns) seenRunIds.add(r.id);

      const poll = (): void => {
        void (async () => {
          const statusRuns = daemon
            ? (await daemon.client.runs.list({ projectId: daemon.projectId, limit: 100 }) as DaemonRunRow[]).map(adaptDaemonRun)
            : store!.getRunsByStatuses(["completed", "failed"]);
          for (const run of statusRuns) {
            if (!seenRunIds.has(run.id)) {
              seenRunIds.add(run.id);
              console.log(formatRunStatus(run));
              console.log("");
            }
          }

          const msgs = daemon
            ? await fetchDaemonMessages(daemon.client, daemon.projectId, { runId, agent: options.agent, unread: options.unread, limit })
            : fetchMessages(store!, runId, options.agent, options.unread ?? false, limit);
          const newMsgs = msgs.filter((m) => !seenIds.has(m.id));
          for (const msg of newMsgs) {
            seenIds.add(msg.id);
            if (fullPayload) {
              console.log(formatMessage(msg, true));
              console.log("");
            } else {
              const rows = [formatMessageTable(msg)];
              console.log(renderMessageTable(rows));
              console.log("");
            }
            if (options.ack) {
              if (daemon) {
                await daemon.client.mail.markRead({ projectId: daemon.projectId, messageId: msg.id });
              } else {
                store!.markMessageRead(msg.id);
              }
            }
          }
        })().catch(() => undefined);
      };

      // Initial poll after setup
      poll();

      const interval = setInterval(poll, 2000);
      // Keep the process alive
      process.on("SIGINT", () => {
        clearInterval(interval);
        store?.close();
        process.exit(0);
      });
    } catch (err: unknown) {
      store?.close();
      const msg = err instanceof Error ? err.message : String(err);
      console.error(`inbox error: ${msg}`);
      process.exit(1);
    }
  });

// ── Helpers ───────────────────────────────────────────────────────────────────

function fetchMessages(
  store: ForemanStore,
  runId: string,
  agent: string | undefined,
  unreadOnly: boolean,
  limit: number,
): Message[] {
  let messages: Message[];
  if (agent) {
    messages = store.getMessages(runId, agent, unreadOnly);
  } else {
    // No agent filter — get all messages for the run
    const all = store.getAllMessages(runId);
    messages = unreadOnly ? all.filter((m) => m.read === 0) : all;
  }
  return messages.slice(0, limit);
}
