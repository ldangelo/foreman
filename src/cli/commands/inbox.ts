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

// ── TableFormatter (tabular message view) ────────────────────────────────────

/**
 * Extract structured fields from a JSON message body.
 * Returns nulls for missing fields, and falls back through:
 * argsPreview → message → body (for ARGS)
 */
export function extractBodyFields(body: string): {
  kind: string | null;
  tool: string | null;
  args: string | null;
} {
  try {
    const parsed = JSON.parse(body) as Record<string, unknown>;
    return {
      kind: typeof parsed["kind"] === "string" ? (parsed["kind"] as string) : null,
      tool: typeof parsed["tool"] === "string" ? (parsed["tool"] as string) : null,
      args:
        (typeof parsed["argsPreview"] === "string" ? (parsed["argsPreview"] as string) : null)
        ?? (typeof parsed["message"] === "string" ? (parsed["message"] as string) : null)
        ?? (typeof parsed["body"] === "string" ? (parsed["body"] as string) : null),
    };
  } catch {
    return { kind: null, tool: null, args: null };
  }
}

/**
 * Truncate a string to `maxWidth` characters, breaking at word boundaries when
 * possible. Appends `…` when truncation occurs.
 */
export function truncate(str: string, maxWidth: number): string {
  if (maxWidth <= 0) return "";
  if (str.length <= maxWidth) return str;
  if (maxWidth === 1) return "…";
  if (maxWidth <= 3) return "…";

  // Try to break at a space before maxWidth
  const slice = str.slice(0, maxWidth);
  const lastSpace = slice.lastIndexOf(" ");
  if (lastSpace > 0) {
    return str.slice(0, lastSpace) + "…";
  }
  return slice.slice(0, maxWidth - 1) + "…";
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
 * Formats inbox messages as a table with aligned columns:
 * DATETIME | TICKET | SENDER | RECEIVER | KIND | TOOL | ARGS
 */
export class TableFormatter {
  private readonly terminalWidth: number;

  constructor({ terminalWidth }: { terminalWidth: number }) {
    this.terminalWidth = terminalWidth;
  }

  /**
   * Format a timestamp as `YYYY-MM-DD HH:MM:SS`.
   */
  private formatDatetime(isoStr: string): string {
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

  /**
   * Truncate run_id with middle-cut when longer than 20 chars.
   * e.g. `run-very-long-id-that-exceeds…` showing prefix + `…` + suffix.
   */
  private middleCutTicket(id: string): string {
    const MAX = 20;
    if (id.length <= MAX) return id;
    // Show: prefix (7 chars) + `…` + suffix (rest)
    const prefix = id.slice(0, 7);
    const suffix = id.slice(id.length - (MAX - 7 - 1));
    return `${prefix}…${suffix}`;
  }

  /**
   * Format a single message row.
   */
  formatRow(msg: Message): FormattedRow {
    const { kind, tool, args } = extractBodyFields(msg.body);
    const DASH = "—";
    const ARGS_MAX = 30;

    return {
      columns: {
        datetime: this.formatDatetime(msg.created_at),
        ticket: this.middleCutTicket(msg.run_id),
        sender: msg.sender_agent_type,
        receiver: msg.recipient_agent_type,
        kind: kind ?? DASH,
        tool: tool ?? DASH,
        args: truncate(args ?? DASH, ARGS_MAX),
      },
      raw: msg,
    };
  }

  /**
   * Compute column widths for a set of messages, clamped to min/max constraints.
   */
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

    // Base headers
    const base = { datetime: 19, ticket: 8, sender: 8, receiver: 8, kind: 4, tool: 4, args: 4 };

    // Compute max content per column
    const computed = {
      datetime: Math.max(base.datetime, ...rows.map((r) => r.columns.datetime.length)),
      ticket: Math.max(base.ticket, ...rows.map((r) => r.columns.ticket.length)),
      sender: Math.max(base.sender, ...rows.map((r) => r.columns.sender.length)),
      receiver: Math.max(base.receiver, ...rows.map((r) => r.columns.receiver.length)),
      kind: Math.max(base.kind, ...rows.map((r) => r.columns.kind.length)),
      tool: Math.max(base.tool, ...rows.map((r) => r.columns.tool.length)),
      args: Math.max(base.args, ...rows.map((r) => r.columns.args.length)),
    };

    // Clamp TICKET to max 20
    computed.ticket = Math.min(computed.ticket, 20);

    // Clamp DATETIME (fixed at 19)
    computed.datetime = 19;

    // Clamp sender/receiver to min 8, max 15
    computed.sender = Math.min(Math.max(computed.sender, 8), 15);
    computed.receiver = Math.min(Math.max(computed.receiver, 8), 15);

    // Clamp kind/tool to max 12
    computed.kind = Math.min(computed.kind, 12);
    computed.tool = Math.min(computed.tool, 12);

    // Distribute extra terminal width to ARGS
    const fixed =
      computed.datetime +
      computed.ticket +
      computed.sender +
      computed.receiver +
      computed.kind +
      computed.tool +
      7; // 7 spaces between columns
    const available = this.terminalWidth - fixed;
    computed.args = Math.max(computed.args, Math.min(available, 80));

    return computed;
  }

  /**
   * Build the column headers line.
   */
  formatHeader(): string {
    // Headers are fixed-width labels
    return (
      "DATETIME          TICKET       SENDER     RECEIVER   KIND       TOOL       ARGS"
    );
  }

  /**
   * Render a separator line of dashes.
   */
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

  /**
   * Format a single row as a space-separated line.
   */
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

  /**
   * Format an array of messages as a complete table string.
   */
  formatTable(messages: Message[]): string {
    if (messages.length === 0) {
      return this.formatHeader() + "\n";
    }

    const rows = messages.map((m) => this.formatRow(m));
    const widths = this.calcWidths(messages);

    const lines: string[] = [
      this.formatHeader(),
      this.formatSeparator(widths),
      ...rows.map((r) => this.formatRowLine(r, widths)),
    ];

    return lines.join("\n") + "\n";
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
          const tf = new TableFormatter({ terminalWidth: getTerminalWidth() });
          console.log(`\nInbox — all runs${options.agent ? `  agent: ${options.agent}` : ""}\n${"─".repeat(70)}`);
          if (fullPayload) {
            for (const msg of messages) {
              console.log(formatMessage(msg, true));
              console.log("");
            }
          } else {
            console.log(tf.formatTable(messages));
          }
          console.log(`${"─".repeat(70)}\n${messages.length} message(s) shown.`);
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
          const tf = new TableFormatter({ terminalWidth: getTerminalWidth() });
          if (fullPayload) {
            for (const m of initialGlobal) { console.log(formatMessage(m, true)); console.log(""); seenIds.add(m.id); }
          } else {
            console.log(tf.formatTable(initialGlobal));
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
            const tf = new TableFormatter({ terminalWidth: getTerminalWidth() });
            for (const msg of msgs.filter((m) => !seenIds.has(m.id))) {
              seenIds.add(msg.id);
              if (fullPayload) {
                console.log(formatMessage(msg, true));
              } else {
                console.log(tf.formatTable([msg]));
              }
              console.log("");
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
          const tf = new TableFormatter({ terminalWidth: getTerminalWidth() });
          console.log(`\nInbox — run: ${runId}${seedLabel}${options.agent ? `  agent: ${options.agent}` : ""}\n${"─".repeat(70)}`);
          if (fullPayload) {
            for (const msg of messages) {
              console.log(formatMessage(msg, true));
              console.log("");
            }
          } else {
            console.log(tf.formatTable(messages));
          }
          console.log(`${"─".repeat(70)}\n${messages.length} message(s) shown.`);
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
        const tf = new TableFormatter({ terminalWidth: getTerminalWidth() });
        if (fullPayload) {
          for (const m of initial) {
            console.log(formatMessage(m, true));
            console.log("");
            seenIds.add(m.id);
          }
        } else {
          console.log(tf.formatTable(initial));
          for (const m of initial) seenIds.add(m.id);
        }
        console.log(`── live ─────────────────────────────────────────────────────────────\n`);
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
          const tf = new TableFormatter({ terminalWidth: getTerminalWidth() });
          for (const msg of newMsgs) {
            seenIds.add(msg.id);
            if (fullPayload) {
              console.log(formatMessage(msg, true));
            } else {
              console.log(tf.formatTable([msg]));
            }
            console.log("");
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
