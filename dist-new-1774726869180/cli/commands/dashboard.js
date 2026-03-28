import { Command } from "commander";
import chalk from "chalk";
import { ForemanStore } from "../../lib/store.js";
import { elapsed, renderAgentCard } from "../watch-ui.js";
import { BeadsRustClient } from "../../lib/beads-rust.js";
/**
 * Fetch br task counts for the compact status view (used by --simple mode).
 * Returns zeros if br is not initialized or binary is missing.
 */
export async function fetchDashboardTaskCounts(projectPath) {
    const brClient = new BeadsRustClient(projectPath);
    let openIssues = [];
    try {
        openIssues = await brClient.list();
    }
    catch { /* br not available */ }
    let closedIssues = [];
    try {
        closedIssues = await brClient.list({ status: "closed" });
    }
    catch { /* no closed */ }
    let readyIssues = [];
    try {
        readyIssues = await brClient.ready();
    }
    catch { /* br ready failed */ }
    const inProgress = openIssues.filter((i) => i.status === "in_progress").length;
    const completed = closedIssues.length;
    const readyIds = new Set(readyIssues.map((i) => i.id));
    const ready = readyIssues.length;
    const blocked = openIssues.filter((i) => i.status !== "in_progress" && !readyIds.has(i.id)).length;
    const total = openIssues.length + completed;
    return { total, ready, inProgress, completed, blocked };
}
// ── Event icons ──────────────────────────────────────────────────────────
const EVENT_ICONS = {
    dispatch: "⬇",
    claim: "→",
    complete: "✓",
    fail: "✗",
    stuck: "⚠",
    restart: "↺",
    recover: "⚡",
    merge: "⊕",
    conflict: "⊘",
    "test-fail": "⊘",
    "pr-created": "↑",
};
const RULE = chalk.dim("─".repeat(60));
const THICK_RULE = chalk.dim("━".repeat(60));
// ── Pure display functions ────────────────────────────────────────────────
/**
 * Format a single event as a compact timeline line.
 */
export function renderEventLine(event) {
    const icon = EVENT_ICONS[event.event_type] ?? "•";
    const age = elapsed(event.created_at);
    let detail = "";
    if (event.details) {
        try {
            const parsed = JSON.parse(event.details);
            const parts = [];
            if (parsed.seedId)
                parts.push(String(parsed.seedId));
            if (parsed.phase)
                parts.push(`phase:${parsed.phase}`);
            if (parsed.title && parsed.title !== parsed.seedId)
                parts.push(String(parsed.title));
            if (parsed.reason)
                parts.push(String(parsed.reason).slice(0, 60));
            if (parts.length > 0)
                detail = ` — ${parts.join(" ")}`;
        }
        catch {
            detail = ` — ${event.details.slice(0, 60)}`;
        }
    }
    const typeColor = event.event_type === "fail" || event.event_type === "conflict" || event.event_type === "test-fail"
        ? chalk.red
        : event.event_type === "stuck"
            ? chalk.yellow
            : event.event_type === "complete" || event.event_type === "merge"
                ? chalk.green
                : chalk.dim;
    return `  ${typeColor(icon)} ${chalk.dim(event.event_type)}${chalk.dim(detail)} ${chalk.dim(`(${age} ago)`)}`;
}
/**
 * Render a summary line for a project header.
 */
export function renderProjectHeader(project, activeCount, metrics) {
    const lines = [];
    const costStr = metrics.totalCost > 0
        ? chalk.yellow(`$${metrics.totalCost.toFixed(2)} spent`)
        : chalk.dim("$0.00 spent");
    const tokenStr = metrics.totalTokens > 0
        ? chalk.dim(`${(metrics.totalTokens / 1000).toFixed(1)}k tokens`)
        : "";
    const statusParts = [costStr];
    if (tokenStr)
        statusParts.push(tokenStr);
    lines.push(`${chalk.bold.cyan("PROJECT:")} ${chalk.bold(project.name)}  ${chalk.dim(project.path)}`);
    lines.push(`  ${statusParts.join("  ")}  ${chalk.blue(`${activeCount} active agent${activeCount !== 1 ? "s" : ""}`)}`);
    return lines.join("\n");
}
/**
 * Render the full dashboard display as a string.
 */
export function renderDashboard(state) {
    const lines = [];
    // Header
    lines.push(`${chalk.bold("Foreman Dashboard")} ${chalk.dim("— Agent Observability")}  ${chalk.dim("(Ctrl+C to detach)")}`);
    lines.push(THICK_RULE);
    lines.push("");
    if (state.projects.length === 0) {
        lines.push(chalk.dim("  No projects registered. Run 'foreman init' to get started."));
        lines.push("");
        lines.push(THICK_RULE);
        lines.push(chalk.dim(`Last updated: ${state.lastUpdated.toLocaleTimeString()}`));
        return lines.join("\n");
    }
    for (const project of state.projects) {
        const activeRuns = state.activeRuns.get(project.id) ?? [];
        const completedRuns = state.completedRuns.get(project.id) ?? [];
        const metrics = state.metrics.get(project.id) ?? {
            totalCost: 0, totalTokens: 0, tasksByStatus: {}, costByRuntime: [],
        };
        const events = state.events.get(project.id) ?? [];
        // Project header
        lines.push(renderProjectHeader(project, activeRuns.length, metrics));
        lines.push(RULE);
        // Active agents
        if (activeRuns.length > 0) {
            lines.push(chalk.bold("  ACTIVE AGENTS:"));
            for (const run of activeRuns) {
                const progress = state.progresses.get(run.id) ?? null;
                const card = renderAgentCard(run, progress)
                    .split("\n")
                    .map((l) => "    " + l)
                    .join("\n");
                lines.push(card);
                lines.push("");
            }
        }
        else {
            lines.push(chalk.dim("  (no agents running)"));
            lines.push("");
        }
        // Recently completed agents (show up to 3)
        const recentCompleted = completedRuns.slice(0, 3);
        if (recentCompleted.length > 0) {
            lines.push(chalk.bold("  RECENTLY COMPLETED:"));
            for (const run of recentCompleted) {
                const progress = state.progresses.get(run.id) ?? null;
                const card = renderAgentCard(run, progress, false)
                    .split("\n")
                    .map((l) => "    " + l)
                    .join("\n");
                lines.push(card);
            }
            lines.push("");
        }
        // Recent events
        if (events.length > 0) {
            lines.push(chalk.bold("  RECENT EVENTS:"));
            for (const event of events) {
                lines.push(renderEventLine(event));
            }
            lines.push("");
        }
        lines.push("");
    }
    // Footer with global totals
    lines.push(THICK_RULE);
    let totalCost = 0;
    let totalTokens = 0;
    let totalActive = 0;
    for (const [, metrics] of state.metrics) {
        totalCost += metrics.totalCost;
        totalTokens += metrics.totalTokens;
    }
    for (const [, runs] of state.activeRuns) {
        totalActive += runs.length;
    }
    lines.push(`${chalk.bold("TOTALS")}  ` +
        `${chalk.blue(`${totalActive} active`)}  ` +
        `${chalk.yellow(`$${totalCost.toFixed(2)}`)}  ` +
        `${chalk.dim(`${(totalTokens / 1000).toFixed(1)}k tokens`)}`);
    lines.push(chalk.dim(`Last updated: ${state.lastUpdated.toLocaleTimeString()}`));
    return lines.join("\n");
}
// ── Data polling ─────────────────────────────────────────────────────────
/**
 * Collect dashboard data from the store.
 */
export function pollDashboard(store, projectId, eventsLimit = 8) {
    const projects = projectId
        ? [store.getProject(projectId)].filter((p) => p !== null)
        : store.listProjects();
    const activeRuns = new Map();
    const completedRuns = new Map();
    const progresses = new Map();
    const metrics = new Map();
    const events = new Map();
    for (const project of projects) {
        const active = store.getActiveRuns(project.id);
        activeRuns.set(project.id, active);
        // Recently completed (last 5)
        const completed = store.getRunsByStatus("completed", project.id).slice(0, 5);
        completedRuns.set(project.id, completed);
        // Get progress for all relevant runs
        for (const run of [...active, ...completed]) {
            if (!progresses.has(run.id)) {
                progresses.set(run.id, store.getRunProgress(run.id));
            }
        }
        metrics.set(project.id, store.getMetrics(project.id));
        events.set(project.id, store.getEvents(project.id, eventsLimit));
    }
    return {
        projects,
        activeRuns,
        completedRuns,
        progresses,
        metrics,
        events,
        lastUpdated: new Date(),
    };
}
// ── Simple (compact) dashboard renderer ─────────────────────────────────
/**
 * Render a simplified single-project dashboard view.
 * Used by `dashboard --simple` for a compact status display similar to
 * `foreman status --watch` but using the dashboard's data layer.
 *
 * Shows: task counts (from br), active agents, costs — no event timeline,
 * no recently-completed section, no multi-project header.
 */
export function renderSimpleDashboard(state, counts, projectId) {
    const lines = [];
    // Pick the target project (first, or the filtered one)
    const project = projectId
        ? state.projects.find((p) => p.id === projectId)
        : state.projects[0];
    lines.push(`${chalk.bold("Foreman Status")} ${chalk.dim("— compact view")}  ${chalk.dim("(Ctrl+C to stop)")}`);
    lines.push(THICK_RULE);
    lines.push("");
    // Task counts section
    lines.push(chalk.bold("Tasks"));
    lines.push(`  Total:       ${chalk.white(counts.total)}`);
    lines.push(`  Ready:       ${chalk.green(counts.ready)}`);
    lines.push(`  In Progress: ${chalk.yellow(counts.inProgress)}`);
    lines.push(`  Completed:   ${chalk.cyan(counts.completed)}`);
    if (counts.blocked > 0) {
        lines.push(`  Blocked:     ${chalk.red(counts.blocked)}`);
    }
    lines.push("");
    if (!project) {
        lines.push(chalk.dim("  No projects registered. Run 'foreman init' to get started."));
        lines.push("");
        lines.push(THICK_RULE);
        lines.push(chalk.dim(`Last updated: ${state.lastUpdated.toLocaleTimeString()}`));
        return lines.join("\n");
    }
    const activeRuns = state.activeRuns.get(project.id) ?? [];
    const projectMetrics = state.metrics.get(project.id) ?? {
        totalCost: 0, totalTokens: 0, tasksByStatus: {}, costByRuntime: [],
    };
    // Active agents
    lines.push(chalk.bold("Active Agents"));
    if (activeRuns.length === 0) {
        lines.push(chalk.dim("  (no agents running)"));
    }
    else {
        for (const run of activeRuns) {
            const progress = state.progresses.get(run.id) ?? null;
            const card = renderAgentCard(run, progress)
                .split("\n")
                .map((l) => "  " + l)
                .join("\n");
            lines.push(card);
        }
    }
    lines.push("");
    // Cost summary (only if non-zero)
    if (projectMetrics.totalCost > 0) {
        lines.push(chalk.bold("Costs"));
        lines.push(`  Total: ${chalk.yellow(`$${projectMetrics.totalCost.toFixed(2)}`)}`);
        lines.push(`  Tokens: ${chalk.dim(`${(projectMetrics.totalTokens / 1000).toFixed(1)}k`)}`);
        lines.push("");
    }
    lines.push(THICK_RULE);
    lines.push(chalk.dim(`Last updated: ${state.lastUpdated.toLocaleTimeString()}`));
    lines.push(chalk.dim(`Tip: use 'foreman status --live' for a full unified dashboard`));
    return lines.join("\n");
}
// ── Command ───────────────────────────────────────────────────────────────
export const dashboardCommand = new Command("dashboard")
    .description("Live agent observability dashboard with real-time TUI")
    .option("--interval <ms>", "Polling interval in milliseconds", "3000")
    .option("--project <id>", "Filter to specific project ID")
    .option("--no-watch", "Single snapshot, no polling")
    .option("--events <n>", "Number of recent events to show per project", "8")
    .option("--simple", "Compact single-project view with task counts (like 'foreman status --watch')")
    .action(async (opts) => {
    const store = ForemanStore.forProject(process.cwd());
    const intervalMs = Math.max(1000, parseInt(opts.interval, 10) || 3000);
    const projectId = opts.project;
    const watch = opts.watch !== false;
    const eventsLimit = Math.max(1, parseInt(opts.events, 10) || 8);
    const simple = opts.simple === true;
    // ── Simple (compact) mode ─────────────────────────────────────────────
    if (simple) {
        // Tip: prefer 'foreman status --live' for the full unified experience
        const projectPath = process.cwd();
        // Single-shot simple mode
        if (!watch) {
            try {
                const state = pollDashboard(store, projectId, eventsLimit);
                let counts = { total: 0, ready: 0, inProgress: 0, completed: 0, blocked: 0 };
                try {
                    counts = await fetchDashboardTaskCounts(projectPath);
                }
                catch { /* ignore */ }
                console.log(renderSimpleDashboard(state, counts, projectId));
            }
            finally {
                store.close();
            }
            return;
        }
        // Live simple mode
        let detachedSimple = false;
        const onSigintSimple = () => {
            if (detachedSimple)
                return;
            detachedSimple = true;
            process.stdout.write("\x1b[?25h\n");
            console.log(chalk.dim("  Detached — agents continue in background."));
            console.log(chalk.dim("  Tip: 'foreman status --live' for a full unified dashboard."));
            store.close();
            process.exit(0);
        };
        process.on("SIGINT", onSigintSimple);
        process.stdout.write("\x1b[?25l");
        try {
            while (!detachedSimple) {
                const state = pollDashboard(store, projectId, eventsLimit);
                let counts = { total: 0, ready: 0, inProgress: 0, completed: 0, blocked: 0 };
                try {
                    counts = await fetchDashboardTaskCounts(projectPath);
                }
                catch { /* ignore */ }
                const display = renderSimpleDashboard(state, counts, projectId);
                process.stdout.write("\x1B[2J\x1B[H" + display + "\n");
                await new Promise((r) => setTimeout(r, intervalMs));
            }
        }
        finally {
            process.stdout.write("\x1b[?25h");
            process.removeListener("SIGINT", onSigintSimple);
            store.close();
        }
        return;
    }
    // ── Single-shot full mode ─────────────────────────────────────────────
    if (!watch) {
        try {
            const state = pollDashboard(store, projectId, eventsLimit);
            console.log(renderDashboard(state));
        }
        finally {
            store.close();
        }
        return;
    }
    // ── Live full dashboard mode ──────────────────────────────────────────
    let detached = false;
    const onSigint = () => {
        if (detached)
            return;
        detached = true;
        process.stdout.write("\x1b[?25h\n"); // restore cursor
        console.log(chalk.dim("  Detached — agents continue in background."));
        console.log(chalk.dim("  Check status: foreman status"));
        console.log(chalk.dim("  Monitor runs: foreman monitor\n"));
        store.close();
        process.exit(0);
    };
    process.on("SIGINT", onSigint);
    process.stdout.write("\x1b[?25l"); // hide cursor
    try {
        while (!detached) {
            const state = pollDashboard(store, projectId, eventsLimit);
            const display = renderDashboard(state);
            process.stdout.write("\x1B[2J\x1B[H" + display + "\n");
            await new Promise((r) => setTimeout(r, intervalMs));
        }
    }
    finally {
        process.stdout.write("\x1b[?25h"); // restore cursor on any exit
        process.removeListener("SIGINT", onSigint);
        // Belt-and-suspenders: onSigint calls process.exit(0) before this finally
        // can run in the normal SIGINT path, but this guards against any future
        // exit path that doesn't go through onSigint.
        store.close();
    }
});
//# sourceMappingURL=dashboard.js.map