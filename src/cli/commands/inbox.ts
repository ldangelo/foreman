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
import { getRepoRoot } from "../../lib/git.js";

// ── Formatting helpers ────────────────────────────────────────────────────────

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

function formatMessage(msg: Message): string {
  const ts = formatTimestamp(msg.created_at);
  const readMark = msg.read === 1 ? " [read]" : "";
  const header = `[${ts}] ${msg.sender_agent_type} → ${msg.recipient_agent_type}  |  ${msg.subject}${readMark}`;
  const preview = msg.body.slice(0, 120).replace(/\n/g, " ");
  const ellipsis = msg.body.length > 120 ? "..." : "";
  return `${header}\n  ${preview}${ellipsis}`;
}

// ── Run status formatting ─────────────────────────────────────────────────────

function formatRunStatus(run: Run): string {
  const ts = formatTimestamp(new Date().toISOString());
  const statusStr = run.status === "completed"
    ? chalk.green(`COMPLETED`)
    : chalk.red(`FAILED`);
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

export const inboxCommand = new Command("inbox")
  .description("View the SQLite message inbox for agents in a pipeline run")
  .option("--agent <name>", "Filter to a specific agent/role (default: show all)")
  .option("--run <id>", "Filter to a specific run ID (default: latest run)")
  .option("--seed <id>", "Resolve run by seed/bead ID (uses most recent run for that seed)")
  .option("--watch", "Poll every 2s for new messages (shows only new ones)")
  .option("--unread", "Show only unread messages")
  .option("--limit <n>", "Max messages to show", "50")
  .option("--ack", "Mark shown messages as read after displaying them")
  .action(async (options: {
    agent?: string;
    run?: string;
    seed?: string;
    watch?: boolean;
    unread?: boolean;
    limit?: string;
    ack?: boolean;
  }) => {
    const limit = parseInt(options.limit ?? "50", 10);

    // Resolve the project root so we can open the correct store
    let projectPath: string;
    try {
      projectPath = await getRepoRoot(process.cwd());
    } catch {
      projectPath = process.cwd();
    }

    const store = ForemanStore.forProject(projectPath);

    try {
      const runId = options.run
        ?? (options.seed ? resolveRunIdBySeed(store, options.seed) : null)
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
            console.log(formatMessage(msg));
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
          console.log(formatMessage(m));
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
          console.log(formatMessage(msg));
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
