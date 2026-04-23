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
import { ForemanStore } from "../../lib/store.js";
import type { Message, Run } from "../../lib/store.js";
import { VcsBackendFactory } from "../../lib/vcs/index.js";
import { resolveRepoRootProjectPath, requireProjectOrAllInMultiMode } from "./project-task-support.js";

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

    const store = ForemanStore.forProject(projectPath);

    try {
      // ── One-shot global mode (--all without --watch) ───────────────────────
      if (options.all && !options.watch) {
        let messages = store.getAllMessagesGlobal(limit);

        // Apply agent filter (by recipient, matching single-run behavior)
        if (options.agent) {
          messages = messages.filter((m) => m.recipient_agent_type === options.agent);
        }

        // Apply unread filter
        if (options.unread) {
          messages = messages.filter((m) => m.read === 0);
        }

        if (messages.length === 0) {
          console.log(`No ${options.unread ? "unread " : ""}messages found across all runs${options.agent ? ` (agent: ${options.agent})` : ""}.`);
        } else {
          console.log(`\nInbox — all runs${options.agent ? `  agent: ${options.agent}` : ""}\n${"─".repeat(70)}`);
          for (const msg of messages) {
            console.log(formatMessage(msg, fullPayload));
            console.log("");
          }
          console.log(`${"─".repeat(70)}\n${messages.length} message(s) shown.`);
        }

        if (options.ack && messages.length > 0) {
          for (const msg of messages) {
            store.markMessageRead(msg.id);
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
        const initialGlobal = store.getAllMessagesGlobal(limit);
        if (initialGlobal.length > 0) {
          console.log(`── past messages ${"─".repeat(53)}`);
          for (const m of initialGlobal) { console.log(formatMessage(m, fullPayload)); console.log(""); seenIds.add(m.id); }
          console.log(`── live ─────────────────────────────────────────────────────────────\n`);
        }
        const initRuns = store.getRunsByStatuses(["completed", "failed", "running"]);
        for (const r of initRuns) seenRunIds.add(r.id);
        const pollAll = (): void => {
          const statusRuns = store.getRunsByStatuses(["completed", "failed", "running"]);
          for (const run of statusRuns) {
            if (!seenRunIds.has(run.id)) { seenRunIds.add(run.id); console.log(formatRunStatus(run)); console.log(""); }
          }
          const msgs = store.getAllMessagesGlobal(limit);
          for (const msg of msgs.filter((m) => !seenIds.has(m.id))) {
            seenIds.add(msg.id); console.log(formatMessage(msg, fullPayload)); console.log("");
          }
        };
        pollAll();
        const interval = setInterval(pollAll, 2000);
        process.on("SIGINT", () => { clearInterval(interval); store.close(); process.exit(0); });
        return;
      }

      const runId = options.run
        ?? (options.bead ? resolveRunIdBySeed(store, options.bead) : null)
        ?? resolveLatestRunId(store);
      if (!runId) {
        console.error("No runs found. Start a pipeline first with `foreman run`.");
        process.exit(1);
      }

      // Resolve seed ID for display (run record carries seed_id)
      const allRuns = store.getRunsByStatuses(
        ["pending", "running", "completed", "failed", "stuck", "merged", "conflict", "test-failed", "pr-created", "reset"],
      );
      const thisRun = allRuns.find((r) => r.id === runId);
      const seedLabel = thisRun?.seed_id ? `  bead: ${thisRun.seed_id}` : "";

      if (!options.watch) {
        // One-shot: show current run lifecycle status then fetch and display messages
        const runStatusRuns = store.getRunsByStatuses(["completed", "failed"]);
        const currentRun = runStatusRuns.find((r) => r.id === runId);
        if (currentRun) {
          console.log(formatRunStatus(currentRun));
          console.log("");
        }

        const messages = fetchMessages(store, runId, options.agent, options.unread ?? false, limit);
        if (messages.length === 0) {
          console.log(`No ${options.unread ? "unread " : ""}messages for run ${runId}${seedLabel}${options.agent ? ` (agent: ${options.agent})` : ""}.`);
        } else {
          console.log(`\nInbox — run: ${runId}${seedLabel}${options.agent ? `  agent: ${options.agent}` : ""}\n${"─".repeat(70)}`);
          for (const msg of messages) {
            console.log(formatMessage(msg, fullPayload));
            console.log("");
          }
          console.log(`${"─".repeat(70)}\n${messages.length} message(s) shown.`);
        }

        if (options.ack && messages.length > 0) {
          for (const msg of messages) {
            store.markMessageRead(msg.id);
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
      const initial = fetchMessages(store, runId, options.agent, false, limit);
      if (initial.length > 0) {
        console.log(`── past messages ${"─".repeat(53)}`);
        for (const m of initial) {
          console.log(formatMessage(m, fullPayload));
          console.log("");
          seenIds.add(m.id);
        }
        console.log(`── live ─────────────────────────────────────────────────────────────\n`);
      }

      // Seed seenRunIds with any already-completed/failed runs so we only show new transitions
      const initialRuns = store.getRunsByStatuses(["completed", "failed"]);
      for (const r of initialRuns) seenRunIds.add(r.id);

      const poll = (): void => {
        // Poll run lifecycle transitions (completed / failed)
        const statusRuns = store.getRunsByStatuses(["completed", "failed"]);
        for (const run of statusRuns) {
          if (!seenRunIds.has(run.id)) {
            seenRunIds.add(run.id);
            console.log(formatRunStatus(run));
            console.log("");
          }
        }

        // Poll messages
        const msgs = fetchMessages(store, runId, options.agent, options.unread ?? false, limit);
        const newMsgs = msgs.filter((m) => !seenIds.has(m.id));
        for (const msg of newMsgs) {
          seenIds.add(msg.id);
          console.log(formatMessage(msg, fullPayload));
          console.log("");
          if (options.ack) {
            store.markMessageRead(msg.id);
          }
        }
      };

      // Initial poll after setup
      poll();

      const interval = setInterval(poll, 2000);
      // Keep the process alive
      process.on("SIGINT", () => {
        clearInterval(interval);
        store.close();
        process.exit(0);
      });
    } catch (err: unknown) {
      store.close();
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
