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
import { getRepoRoot } from "../../lib/git.js";
// ── Formatting helpers ────────────────────────────────────────────────────────
function formatTimestamp(isoStr) {
    try {
        const d = new Date(isoStr);
        const pad = (n) => String(n).padStart(2, "0");
        return (`${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
            `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`);
    }
    catch {
        return isoStr;
    }
}
function formatMessage(msg) {
    const ts = formatTimestamp(msg.created_at);
    const readMark = msg.read === 1 ? " [read]" : "";
    const header = `[${ts}] ${msg.sender_agent_type} → ${msg.recipient_agent_type}  |  ${msg.subject}${readMark}`;
    const preview = msg.body.slice(0, 120).replace(/\n/g, " ");
    const ellipsis = msg.body.length > 120 ? "..." : "";
    return `${header}\n  ${preview}${ellipsis}`;
}
// ── Run status formatting ─────────────────────────────────────────────────────
function formatRunStatus(run) {
    const ts = formatTimestamp(new Date().toISOString());
    let statusStr;
    if (run.status === "completed") {
        statusStr = chalk.green("COMPLETED");
    }
    else if (run.status === "failed") {
        statusStr = chalk.red("FAILED");
    }
    else if (run.status === "running") {
        statusStr = chalk.blue("RUNNING");
    }
    else {
        statusStr = chalk.yellow(run.status.toUpperCase());
    }
    return `[${ts}] ${chalk.bold("●")} ${run.seed_id} ${statusStr} (run ${run.id})`;
}
// ── Run resolution ────────────────────────────────────────────────────────────
function resolveLatestRunId(store) {
    // Get the most recently created run (any status)
    const runs = store.getRunsByStatuses(["pending", "running", "completed", "failed", "stuck", "merged", "conflict", "test-failed", "pr-created", "reset"]);
    if (runs.length === 0)
        return null;
    // Runs are returned in DESC created_at order
    return runs[0]?.id ?? null;
}
function resolveRunIdBySeed(store, seedId) {
    const runs = store.getRunsByStatuses(["pending", "running", "completed", "failed", "stuck", "merged", "conflict", "test-failed", "pr-created", "reset"]);
    const seedRuns = runs.filter((r) => r.seed_id === seedId);
    // Runs are returned DESC by created_at, so [0] is most recent
    return seedRuns[0]?.id ?? null;
}
// ── Main command ──────────────────────────────────────────────────────────────
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
    .action(async (options) => {
    const limit = parseInt(options.limit ?? "50", 10);
    // Resolve the project root so we can open the correct store
    let projectPath;
    try {
        projectPath = await getRepoRoot(process.cwd());
    }
    catch {
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
            }
            else {
                console.log(`\nInbox — all runs${options.agent ? `  agent: ${options.agent}` : ""}\n${"─".repeat(70)}`);
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
        // ── Global watch mode (--all --watch) ──────────────────────────────────
        if (options.all && options.watch) {
            console.log("Watching all runs... (Ctrl-C to stop)\n");
            const seenIds = new Set();
            const seenRunIds = new Set();
            const initialGlobal = store.getAllMessagesGlobal(limit);
            if (initialGlobal.length > 0) {
                console.log(`── past messages ${"─".repeat(53)}`);
                for (const m of initialGlobal) {
                    console.log(formatMessage(m));
                    console.log("");
                    seenIds.add(m.id);
                }
                console.log(`── live ─────────────────────────────────────────────────────────────\n`);
            }
            const initRuns = store.getRunsByStatuses(["completed", "failed", "running"]);
            for (const r of initRuns)
                seenRunIds.add(r.id);
            const pollAll = () => {
                const statusRuns = store.getRunsByStatuses(["completed", "failed", "running"]);
                for (const run of statusRuns) {
                    if (!seenRunIds.has(run.id)) {
                        seenRunIds.add(run.id);
                        console.log(formatRunStatus(run));
                        console.log("");
                    }
                }
                const msgs = store.getAllMessagesGlobal(limit);
                for (const msg of msgs.filter((m) => !seenIds.has(m.id))) {
                    seenIds.add(msg.id);
                    console.log(formatMessage(msg));
                    console.log("");
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
        const allRuns = store.getRunsByStatuses(["pending", "running", "completed", "failed", "stuck", "merged", "conflict", "test-failed", "pr-created", "reset"]);
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
            }
            else {
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
        const seenIds = new Set();
        const seenRunIds = new Set();
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
        for (const r of initialRuns)
            seenRunIds.add(r.id);
        const poll = () => {
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
    }
    catch (err) {
        store.close();
        const msg = err instanceof Error ? err.message : String(err);
        console.error(`inbox error: ${msg}`);
        process.exit(1);
    }
});
// ── Helpers ───────────────────────────────────────────────────────────────────
function fetchMessages(store, runId, agent, unreadOnly, limit) {
    let messages;
    if (agent) {
        messages = store.getMessages(runId, agent, unreadOnly);
    }
    else {
        // No agent filter — get all messages for the run
        const all = store.getAllMessages(runId);
        messages = unreadOnly ? all.filter((m) => m.read === 0) : all;
    }
    return messages.slice(0, limit);
}
//# sourceMappingURL=inbox.js.map