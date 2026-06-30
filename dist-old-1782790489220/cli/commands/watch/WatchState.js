/**
 * WatchState — State machine for the unified watch poll + render cycle.
 *
 * Responsibilities:
 * - Poll cycle state: store, runs, messages, task counts
 * - Key handling state: focused panel, selected task
 * - Live inbox tracking: last seen message ID for new-message detection
 * - SIGWINCH handling: terminal resize signal
 */
import chalk from "chalk";
import { resolve } from "node:path";
import { foremanBackendMode } from "../../../lib/backend-mode.js";
import { ElixirServerClient } from "../../../lib/elixir-server-client.js";
import { ElixirServerManager } from "../../../lib/elixir-server-manager.js";
import { fetchDaemonDashboardState } from "../../dashboard-state.js";
import { fetchTaskCounts } from "../../../lib/task-client-factory.js";
import { createTrpcClient } from "../../../lib/trpc-client.js";
import { listRegisteredProjects } from "../project-task-support.js";
export function nextPanel(current) {
    const order = ["agents", "board", "inbox", "events"];
    const idx = order.indexOf(current);
    return order[(idx + 1) % order.length];
}
// ── Initial state ────────────────────────────────────────────────────────
export function initialWatchState() {
    return {
        dashboard: null,
        agents: [],
        board: null,
        inbox: null,
        events: null,
        taskCounts: null,
        lastPollMs: 0,
        lastInboxPollMs: 0,
        inboxLastSeenId: null,
        eventsLastSeenId: null,
        focusedPanel: "agents",
        expandedAgentIndices: new Set(),
        selectedTaskIndex: -1,
        showHelp: false,
        errorMessage: null,
        agentsOffline: false,
        boardOffline: false,
        inboxOffline: false,
        eventsOffline: false,
    };
}
async function createElixirWatchClient() {
    const manager = new ElixirServerManager();
    const status = await manager.ensureRunning();
    return new ElixirServerClient(status.url, process.env.FOREMAN_SERVER_AUTH_TOKEN);
}
async function loadBoardSummary(projectPath, projectId) {
    const projects = await listRegisteredProjects();
    const normalizedProjectPath = resolve(projectPath);
    const project = projectId
        ? projects.find((record) => record.id === projectId || record.name === projectId)
        : projects.find((record) => resolve(record.path) === normalizedProjectPath);
    if (!project) {
        return { counts: createEmptyCounts(), total: 0, ready: 0, needsAttention: [] };
    }
    const rows = foremanBackendMode() === "elixir"
        ? (await (await createElixirWatchClient()).listTasks())
            .filter((task) => task.project_id === project.id)
            .map((task) => ({
            id: task.task_id ?? task.id ?? "unknown",
            title: task.title ?? (task.task_id ?? task.id ?? "unknown"),
            status: task.status ?? "backlog",
            priority: typeof task.priority === "number" ? task.priority : 2,
        }))
        : await (async () => {
            const client = createTrpcClient();
            return await client.tasks.list({ projectId: project.id, limit: 1000 });
        })();
    const counts = createEmptyCounts();
    const needsAttention = [];
    for (const row of rows) {
        const normalizedStatus = row.status.replace(/-/g, "_");
        let status;
        if (NEEDS_ATTENTION_STATUSES.has(normalizedStatus)) {
            status = "needs_attention";
        }
        else if (BOARD_STATUS_SET.has(normalizedStatus)) {
            status = normalizedStatus;
        }
        else {
            status = "closed";
        }
        counts[status] += 1;
        if (NEEDS_ATTENTION_STATUSES.has(normalizedStatus)) {
            needsAttention.push({
                ...row,
                projectId: project.id,
                projectName: project.name,
                projectPath: project.path,
            });
        }
    }
    return {
        counts,
        total: countsTotal(counts),
        ready: counts.ready,
        needsAttention: needsAttention.sort((a, b) => a.priority - b.priority),
    };
}
/**
 * Poll all data sources for the main display.
 * Returns null for unavailable sources (graceful degradation).
 */
export async function pollWatchData(projectPath, projectId) {
    // Dashboard state
    let dashboard;
    try {
        dashboard = await fetchDaemonDashboardState(projectPath, projectId)
            ?? { projects: [], activeRuns: new Map(), completedRuns: new Map(), progresses: new Map(), metrics: new Map(), events: new Map(), lastUpdated: new Date() };
    }
    catch {
        dashboard = { projects: [], activeRuns: new Map(), completedRuns: new Map(), progresses: new Map(), metrics: new Map(), events: new Map(), lastUpdated: new Date() };
    }
    // Active agent entries
    const agents = [];
    try {
        const activeRuns = [];
        for (const [, runs] of dashboard.activeRuns) {
            activeRuns.push(...runs);
        }
        for (const run of activeRuns) {
            const progress = dashboard.progresses.get(run.id) ?? null;
            agents.push({ run, progress });
        }
    }
    catch {
        // agents stays empty
    }
    // Board summary
    let board;
    try {
        board = await loadBoardSummary(projectPath, projectId);
    }
    catch {
        board = { counts: createEmptyCounts(), total: 0, ready: 0, needsAttention: [] };
    }
    // Task counts
    let taskCounts = { total: 0, ready: 0, inProgress: 0, completed: 0, blocked: 0 };
    try {
        const currentProject = dashboard.projects[0];
        if (currentProject) {
            if (foremanBackendMode() === "elixir") {
                const tasks = await (await createElixirWatchClient()).listTasks();
                const projectTasks = tasks.filter((task) => task.project_id === currentProject.id);
                taskCounts = {
                    total: projectTasks.length,
                    ready: projectTasks.filter((task) => task.status === "ready").length,
                    inProgress: projectTasks.filter((task) => ["in_progress", "in-progress", "explorer", "developer", "qa", "reviewer", "finalize"].includes(String(task.status ?? ""))).length,
                    completed: projectTasks.filter((task) => ["merged", "closed", "completed", "done"].includes(String(task.status ?? ""))).length,
                    blocked: projectTasks.filter((task) => ["backlog", "blocked", "failed", "stuck", "conflict", "review"].includes(String(task.status ?? ""))).length,
                };
            }
            else {
                const client = createTrpcClient();
                const stats = await client.projects.stats({ projectId: currentProject.id });
                taskCounts = {
                    total: stats.tasks.total,
                    ready: stats.tasks.ready,
                    inProgress: stats.tasks.inProgress,
                    completed: stats.tasks.merged + stats.tasks.closed,
                    blocked: stats.tasks.backlog,
                };
            }
        }
        else {
            taskCounts = await fetchTaskCounts(projectPath);
        }
    }
    catch {
        // ignore
    }
    return { dashboard, agents, board, taskCounts };
}
/**
 * Poll inbox messages for the inbox panel.
 * Returns new messages since `lastSeenId` + total count.
 */
export async function pollInboxData(store, lastSeenId, inboxLimit, runIds, projectPath, projectId) {
    try {
        if (projectPath) {
            try {
                const projects = await listRegisteredProjects();
                const normalizedProjectPath = resolve(projectPath);
                const project = projectId
                    ? projects.find((record) => record.id === projectId || record.name === projectId)
                    : projects.find((record) => resolve(record.path) === normalizedProjectPath);
                if (project) {
                    const allMessages = foremanBackendMode() === "elixir"
                        ? (await (await createElixirWatchClient()).listInbox({ projectId: project.id, limit: 1000 }))
                            .filter((msg) => runIds.length === 0 || !msg.run_id || runIds.includes(String(msg.run_id)))
                            .map((msg) => ({
                            id: String(msg.message_id ?? `${msg.run_id ?? "run"}-${msg.subject ?? "msg"}`),
                            run_id: String(msg.run_id ?? ""),
                            sender_agent_type: String(msg.sender ?? msg.sender_agent_type ?? "agent"),
                            recipient_agent_type: String(msg.recipient ?? msg.recipient_agent_type ?? "run"),
                            subject: String(msg.subject ?? "message"),
                            body: typeof msg.body === "string" ? msg.body : JSON.stringify(msg.body ?? {}),
                            read: msg.unread === false ? 1 : 0,
                            created_at: String(msg.created_at ?? new Date().toISOString()),
                            deleted_at: null,
                        }))
                        : (await Promise.all(runIds.map((runId) => createTrpcClient().runs.listMessages({ runId }))))
                            .flat()
                            .map((msg) => ({
                            id: msg.id,
                            run_id: msg.run_id,
                            sender_agent_type: msg.stream,
                            recipient_agent_type: msg.step_key ?? "run",
                            subject: (msg.chunk || "").trim().slice(0, 60) || msg.stream,
                            body: msg.chunk,
                            read: 0,
                            created_at: msg.created_at,
                            deleted_at: null,
                        }));
                    allMessages.sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime());
                    const totalCount = allMessages.length;
                    const recent = allMessages.slice(0, inboxLimit);
                    const newestId = recent[0]?.id ?? null;
                    const messages = recent.map((msg, i) => ({
                        message: msg,
                        isNew: lastSeenId !== null && i === 0 && msg.id !== lastSeenId,
                    }));
                    return { messages, totalCount, newestId };
                }
            }
            catch {
                // Fall through to legacy local-store inbox path.
            }
        }
        const allMessages = [];
        for (const runId of runIds) {
            const msgs = store.getAllMessages(runId);
            allMessages.push(...msgs);
        }
        // Sort by created_at descending
        allMessages.sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime());
        const totalCount = allMessages.length;
        const recent = allMessages.slice(0, inboxLimit);
        const newestId = recent[0]?.id ?? null;
        const messages = recent.map((msg, i) => ({
            message: msg,
            isNew: lastSeenId !== null && i === 0 && msg.id !== lastSeenId,
        }));
        return { messages, totalCount, newestId };
    }
    catch {
        return { messages: [], totalCount: 0, newestId: null };
    }
}
/**
 * Poll pipeline events for the events panel.
 * Returns events + total count for watched runIds.
 */
export async function pollPipelineEvents(store, lastSeenId, eventsLimit, runIds, projectPath, projectId) {
    try {
        if (projectPath) {
            try {
                const projects = await listRegisteredProjects();
                const normalizedProjectPath = resolve(projectPath);
                const project = projectId
                    ? projects.find((record) => record.id === projectId || record.name === projectId)
                    : projects.find((record) => resolve(record.path) === normalizedProjectPath);
                if (project) {
                    const allEvents = foremanBackendMode() === "elixir"
                        ? (await (await createElixirWatchClient()).listEvents({ projectId: project.id, limit: 1000 }))
                            .filter((event) => runIds.length === 0 || !event.run_id || runIds.includes(String(event.run_id)))
                            .map((event) => ({
                            id: String(event.event_id ?? `${event.run_id ?? "run"}-${event.event_type ?? event.type ?? "event"}`),
                            eventType: String(event.event_type ?? event.type ?? "event"),
                            runId: event.run_id ? String(event.run_id) : null,
                            details: event.payload && typeof event.payload === "object" ? event.payload : null,
                            createdAt: String(event.occurred_at ?? event.created_at ?? new Date().toISOString()),
                            isNew: false,
                        }))
                        : (await Promise.all(runIds.map((runId) => createTrpcClient().runs.listEvents({ runId }))))
                            .flat()
                            .map((row) => ({
                            id: row.id,
                            eventType: row.event_type,
                            runId: row.run_id,
                            details: row.details ? JSON.parse(row.details) : null,
                            createdAt: row.created_at,
                            isNew: lastSeenId !== null && row.id === lastSeenId,
                        }));
                    // Sort by created_at descending (most recent first)
                    allEvents.sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime());
                    const totalCount = allEvents.length;
                    const recent = allEvents.slice(0, eventsLimit);
                    const newestId = recent[0]?.id ?? null;
                    // Mark first event as "new" if it's new since lastSeenId
                    const events = recent.map((e, i) => ({
                        ...e,
                        isNew: lastSeenId !== null && i === 0 && e.id !== lastSeenId,
                    }));
                    return { events, totalCount, newestId };
                }
            }
            catch {
                // Fall through to legacy local-store path.
            }
        }
        // Legacy local-store path
        const allEvents = [];
        for (const runId of runIds) {
            const rows = store.getRunEvents(runId);
            for (const row of rows) {
                allEvents.push({
                    id: row.id,
                    eventType: row.event_type,
                    runId: row.run_id,
                    details: row.details ? JSON.parse(row.details) : null,
                    createdAt: row.created_at,
                    isNew: lastSeenId !== null && row.id === lastSeenId,
                });
            }
        }
        // Sort by created_at descending
        allEvents.sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime());
        const totalCount = allEvents.length;
        const recent = allEvents.slice(0, eventsLimit);
        const newestId = recent[0]?.id ?? null;
        const events = recent.map((e, i) => ({
            ...e,
            isNew: lastSeenId !== null && i === 0 && e.id !== lastSeenId,
        }));
        return { events, totalCount, newestId };
    }
    catch {
        return { events: [], totalCount: 0, newestId: null };
    }
}
// ── Board helpers ─────────────────────────────────────────────────────────
function createEmptyCounts() {
    return {
        backlog: 0,
        ready: 0,
        in_progress: 0,
        needs_attention: 0,
        closed: 0,
    };
}
const BOARD_STATUS_SET = new Set(["backlog", "ready", "in_progress", "needs_attention", "closed"]);
function countsTotal(counts) {
    return Object.values(counts).reduce((sum, n) => sum + n, 0);
}
const NEEDS_ATTENTION_STATUSES = new Set(["conflict", "failed", "stuck", "blocked", "review"]);
/**
 * Handle a single keypress in the watch loop.
 * Returns whether to re-render, wake the poll sleep, or quit.
 */
export function handleWatchKey(state, key) {
    // Global: quit
    if (key === "q" || key === "Q" || key === "\u001B" /* ESC */) {
        return { render: false, wake: false, quit: true, none: false };
    }
    // Global: toggle help
    if (key === "?") {
        state.showHelp = !state.showHelp;
        return { render: true, wake: false, quit: false, none: false };
    }
    // Global: cycle focus
    if (key === "\t" /* Tab */) {
        state.focusedPanel = nextPanel(state.focusedPanel);
        return { render: true, wake: false, quit: false, none: false };
    }
    // Global: open full board
    if (key === "b" || key === "B") {
        // Signal to open foreman board and exit
        return { render: false, wake: false, quit: true, none: false };
    }
    // Global: open full inbox
    if (key === "i" || key === "I") {
        return { render: false, wake: false, quit: true, none: false };
    }
    // Panel-specific keys
    if (state.focusedPanel === "agents") {
        // Tab/1-9 expand agent cards
        if (key === "\t") {
            state.focusedPanel = "board";
            return { render: true, wake: false, quit: false, none: false };
        }
        if (/^[1-9]$/.test(key)) {
            const idx = parseInt(key, 10) - 1;
            if (state.expandedAgentIndices.has(idx)) {
                state.expandedAgentIndices.delete(idx);
            }
            else {
                state.expandedAgentIndices.add(idx);
            }
            return { render: true, wake: false, quit: false, none: false };
        }
        // a = toggle all
        if (key === "a" || key === "A") {
            if (state.expandedAgentIndices.size > 0) {
                state.expandedAgentIndices.clear();
            }
            else {
                for (let i = 0; i < state.agents.length; i++) {
                    state.expandedAgentIndices.add(i);
                }
            }
            return { render: true, wake: false, quit: false, none: false };
        }
    }
    if (state.focusedPanel === "board") {
        // j/k navigation
        if (key === "j" || key === "\u001B[B" /* Down */) {
            if (state.agents.length > 0) {
                state.selectedTaskIndex = Math.min(state.selectedTaskIndex + 1, (state.board?.needsAttention.length ?? 1) - 1);
            }
            return { render: true, wake: false, quit: false, none: false };
        }
        if (key === "k" || key === "\u001B[A" /* Up */) {
            if (state.agents.length > 0) {
                state.selectedTaskIndex = Math.max(state.selectedTaskIndex - 1, 0);
            }
            return { render: true, wake: false, quit: false, none: false };
        }
        // a = approve
        if (key === "a" || key === "A") {
            return { render: true, wake: true, quit: false, none: false };
        }
        // r = retry
        if (key === "r" || key === "R") {
            return { render: true, wake: true, quit: false, none: false };
        }
    }
    if (state.focusedPanel === "inbox") {
        if (key === "\t") {
            state.focusedPanel = "agents";
            return { render: true, wake: false, quit: false, none: false };
        }
    }
    return { render: false, wake: false, quit: false, none: true };
}
// ── Help overlay ──────────────────────────────────────────────────────────
export function renderHelpOverlay(width) {
    const lines = [];
    lines.push(chalk.bold("\n  ── HELP ──────────────────────────────────────────────────"));
    lines.push("");
    lines.push("  Global keys:");
    lines.push("    Tab          Cycle focus: Agents → Board → Inbox");
    lines.push("    ?            Toggle this help overlay");
    lines.push("    b            Open full board (foreman board)");
    lines.push("    i            Open full inbox (foreman inbox)");
    lines.push("    q / Esc      Quit");
    lines.push("");
    lines.push("  Agents panel:");
    lines.push("    1-9          Expand/collapse agent card");
    lines.push("    a            Expand all agents");
    lines.push("");
    lines.push("  Board panel:");
    lines.push("    j / ↓       Select next task");
    lines.push("    k / ↑       Select previous task");
    lines.push("    a            Approve selected backlog task → ready");
    lines.push("    r            Retry selected failed/stuck task → backlog");
    lines.push("");
    lines.push("  ────────────────────────────────────────────────────────────");
    lines.push(chalk.dim("  Press any key to close help"));
    return lines.join("\n");
}
//# sourceMappingURL=WatchState.js.map