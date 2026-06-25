/**
 * `foreman watch` — Single-pane unified operator dashboard.
 *
 * Surfaces three live data streams simultaneously:
 * 1. Agent Panel — Active running agents with phase, cost, tool activity
 * 2. Board Panel — Compact task status summary (read-only)
 * 3. Inbox Panel — Live agent mail stream
 *
 * Keyboard navigation:
 *   Tab        — Cycle focus: Agents → Board → Inbox
 *   1-9        — Expand agent card by index (Agents panel)
 *   a          — Approve backlog task (Board panel, focused)
 *   r          — Retry failed/stuck task (Board panel, focused)
 *   j / k      — Navigate tasks (Board panel)
 *   b          — Open full board (`foreman board`)
 *   i          — Open full inbox (`foreman inbox`)
 *   ?          — Toggle help overlay
 *   q / Esc    — Quit
 *
 * Options:
 *   --refresh <ms>   Refresh interval in ms (default: 5000)
 *   --inbox-limit <n> Max inbox messages shown (default: 5)
 *   --no-watch        One-shot snapshot, then exit
 *   --no-board        Hide board panel
 *   --no-inbox        Hide inbox panel
 *   --project <id>    Filter to specific project
 */

import { Command } from "commander";
import chalk from "chalk";
import { ForemanStore } from "../../../lib/store.js";
import { loadDashboardConfig } from "../../../lib/project-config.js";
import { resolveRepoRootProjectPath } from "../project-task-support.js";
import {
  type WatchState,
  initialWatchState,
  type WatchOptions,
  pollWatchData,
  pollInboxData,
  pollPipelineEvents,
  handleWatchKey,
  nextPanel,
} from "./WatchState.js";
import { renderWatch } from "./render.js";
import { approveTask, retryTask } from "./actions.js";
import { printDeprecationNotice } from "../cli-output.js";
import { foremanBackendMode } from "../../../lib/backend-mode.js";
import { ElixirServerClient, type ElixirEvent, type ElixirInboxMessage, type ElixirRun, type ElixirTask } from "../../../lib/elixir-server-client.js";
import { ElixirServerManager } from "../../../lib/elixir-server-manager.js";

/**
 * `foreman dashboard` is a deprecated alias of `foreman watch`. When the
 * command was invoked via the alias (detected from argv), print a one-line
 * deprecation notice. Exported for testing.
 *
 * Only argv[2] — the command token in `node foreman <command> ...` — is
 * checked, so option values like `foreman watch --project dashboard` never
 * trigger a false positive. (Commander reports the canonical name, not the
 * alias, at action time, so argv inspection is required; a global flag placed
 * before the command would merely skip the notice, which is harmless.)
 */
export function maybePrintDashboardAliasNotice(argv: readonly string[] = process.argv): void {
  if (argv[2] === "dashboard") {
    printDeprecationNotice("foreman dashboard", "foreman watch");
  }
}

function normalizeStatus(value: string | undefined): string {
  return (value ?? "").toLowerCase().replaceAll("_", "-");
}

function activeElixirRuns(runs: ElixirRun[]): ElixirRun[] {
  return runs.filter((run) => ["pending", "running"].includes(normalizeStatus(run.status)));
}

function renderElixirWatchSnapshot(input: {
  projects: Array<{ project_id?: string; id?: string; name?: string }>;
  tasks: ElixirTask[];
  runs: ElixirRun[];
  inbox: ElixirInboxMessage[];
  events: ElixirEvent[];
  options: WatchOptions;
}): string {
  const { projects, tasks, runs, inbox, events, options } = input;
  const activeRuns = activeElixirRuns(runs);
  const counts = tasks.reduce<Record<string, number>>((acc, task) => {
    const status = normalizeStatus(task.status || "backlog");
    acc[status] = (acc[status] || 0) + 1;
    return acc;
  }, {});

  const lines = [
    `${chalk.bold.cyan("FOREMAN WATCH")} — ${chalk.bold("Elixir")}`,
    chalk.dim("─".repeat(Math.min(process.stdout.columns || 120, 80))),
    chalk.dim(`Projects: ${projects.map((project) => project.name || project.project_id || project.id).filter(Boolean).join(", ") || "—"}`),
    "",
    chalk.bold("Agents"),
  ];

  if (activeRuns.length === 0) {
    lines.push(chalk.dim("  (no active runs)"));
  } else {
    for (const run of activeRuns.slice(0, 8)) {
      lines.push(`  ${chalk.cyan(String(run.task_id || run.run_id || run.id))} ${chalk.yellow(String(run.status || "pending"))} ${chalk.dim(String(run.run_id || run.id || ""))}`);
    }
  }

  if (!options.noBoard) {
    lines.push("", chalk.bold("Board"));
    lines.push(`  Total: ${tasks.length}  Ready: ${counts.ready || 0}  In progress: ${counts["in-progress"] || counts.running || 0}  Failed: ${counts.failed || counts.conflict || 0}  Closed: ${counts.closed || counts.merged || counts.completed || 0}`);
  }

  if (!options.noInbox) {
    lines.push("", chalk.bold("Inbox"));
    for (const msg of inbox.slice(0, options.inboxLimit)) {
      lines.push(`  ${chalk.cyan(String(msg.run_id || "—"))} ${String(msg.type || msg.subject || msg.event_type || "message")}`);
    }
    if (inbox.length === 0) lines.push(chalk.dim("  (no messages)"));
  }

  if (!options.noEvents) {
    lines.push("", chalk.bold("Events"));
    for (const event of events.slice(0, options.eventsLimit)) {
      lines.push(`  ${chalk.cyan(String(event.run_id || "—"))} ${String(event.type || event.event_type || "event")}`);
    }
    if (events.length === 0) lines.push(chalk.dim("  (no events)"));
  }

  lines.push("", chalk.dim(`Last updated: ${new Date().toLocaleTimeString()}  |  Ctrl+C to quit`));
  return lines.join("\n");
}

async function renderElixirWatch(options: WatchOptions): Promise<void> {
  const manager = new ElixirServerManager();
  const status = await manager.ensureRunning();
  const client = new ElixirServerClient(status.url, manager.authToken);
  let stopped = false;
  const onSigint = () => {
    stopped = true;
    process.stdout.write("\x1b[?25h\n");
  };
  process.once("SIGINT", onSigint);
  if (process.stdout.isTTY) process.stdout.write("\x1b[?25l");

  try {
    do {
      const [projects, allTasks, allRuns, inbox, events] = await Promise.all([
        client.listProjects(),
        client.listTasks(),
        client.listRuns(options.projectId),
        options.noInbox ? Promise.resolve([]) : client.listInbox({ projectId: options.projectId, limit: options.inboxLimit }),
        options.noEvents ? Promise.resolve([]) : client.listEvents({ projectId: options.projectId, limit: options.eventsLimit }),
      ]);
      const tasks = options.projectId ? allTasks.filter((task) => (task.project_id ?? options.projectId) === options.projectId) : allTasks;
      const runs = options.projectId ? allRuns.filter((run) => (run.project_id ?? options.projectId) === options.projectId) : allRuns;
      const display = renderElixirWatchSnapshot({ projects, tasks, runs, inbox, events, options });
      process.stdout.write("\x1B[2J\x1B[H" + display + "\n");
      if (options.noWatch) break;
      await new Promise((resolve) => setTimeout(resolve, options.refreshMs));
    } while (!stopped);
  } finally {
    if (process.stdout.isTTY) process.stdout.write("\x1b[?25h");
    process.off("SIGINT", onSigint);
  }
}

export const watchCommand = new Command("watch")
  .alias("dashboard")
  .description("Single-pane unified dashboard: agents, board, inbox, and pipeline events")
  .option("--refresh <ms>", "Refresh interval in milliseconds (default: 5000; min: 1000)", "")
  .option("--inbox-limit <n>", "Max inbox messages shown (default: 5)", "")
  .option("--inbox-poll <ms>", "Inbox-only poll interval in ms (default: 2000)", "")
  .option("--events-limit <n>", "Max pipeline events shown (default: 5)", "")
  .option("--no-watch", "One-shot snapshot, no polling")
  .option("--no-board", "Hide board summary panel")
  .option("--no-inbox", "Hide inbox panel")
  .option("--no-events", "Hide pipeline events panel")
  .option("--project <id>", "Filter to specific project ID")
  .action(async (opts: {
    refresh: string;
    "inbox-limit": string;
    "inbox-poll": string;
    "events-limit": string;
    watch: boolean;
    board: boolean;
    inbox: boolean;
    events: boolean;
    project?: string;
  }) => {
    maybePrintDashboardAliasNotice();

    const projectPath = await resolveRepoRootProjectPath({ project: opts.project });

    // Load config
    const config = loadDashboardConfig(projectPath);
    const configRefresh = config.refreshInterval ?? 5000;

    // Parse options
    const rawRefresh = opts.refresh;
    const refreshMs = rawRefresh
      ? Math.max(1000, parseInt(rawRefresh, 10) || configRefresh)
      : configRefresh;

    const inboxLimit = opts["inbox-limit"]
      ? Math.max(1, parseInt(opts["inbox-limit"], 10) || 5)
      : 5;

    const inboxPollMs = opts["inbox-poll"]
      ? Math.max(500, parseInt(opts["inbox-poll"], 10) || 2000)
      : 2000;

    const eventsLimit = opts["events-limit"]
      ? Math.max(1, parseInt(opts["events-limit"], 10) || 5)
      : 5;

    const noWatch = opts.watch === false;
    const noBoard = opts.board === false;
    const noInbox = opts.inbox === false;
    const noEvents = opts.events === false;
    const projectId = opts.project;

    // Options object for poll functions
    const options: WatchOptions = {
      refreshMs,
      inboxLimit,
      inboxPollMs,
      eventsLimit,
      noWatch,
      noBoard,
      noInbox,
      noEvents,
      projectId,
    };

    if (foremanBackendMode() === "elixir") {
      await renderElixirWatch(options);
      return;
    }

    // Postgres-backed store is only still needed for inbox fallback.
    const store = noInbox ? null : ForemanStore.forProject(projectPath);

    // SIGWINCH handler for resize
    let winchOccurred = false;
    const onWinch = () => { winchOccurred = true; };
    if (process.stdout.isTTY) {
      try {
        // Node.js doesn't have native SIGWINCH handler, but we can check on resize
        process.stdout.on("resize", onWinch);
      } catch { /* ignore */ }
    }

    // SIGINT cleanup
    let detached = false;
    const onSigint = () => {
      if (detached) return;
      detached = true;
      process.stdout.write("\x1b[?25h\n"); // restore cursor
      console.log(chalk.dim("  Detached."));
      store?.close();
      process.exit(0);
    };
    process.on("SIGINT", onSigint);

    // Hide cursor
    if (process.stdout.isTTY) {
      process.stdout.write("\x1b[?25l");
    }

    // State
    let state = initialWatchState();

    // Keyboard handling
    let stdinRawMode = false;
    let sleepResolve: (() => void) | null = null;

    const wakeAndRender = () => {
      if (sleepResolve) {
        sleepResolve();
        sleepResolve = null;
      }
    };

    const handleKey = (key: string) => {
      const result = handleWatchKey(state, key);

      if (result.quit) {
        detached = true;
        wakeAndRender();
        return;
      }

      // Board actions: a = approve, r = retry
      if (state.focusedPanel === "board") {
        const task = state.board?.needsAttention[state.selectedTaskIndex];
        if (task) {
          if (key === "a" || key === "A") {
            if (task.status === "backlog") {
              void approveTask(task.id, projectPath).then((ok) => {
                if (!ok) {
                  state.errorMessage = "Failed to approve task";
                }
                wakeAndRender();
              });
            } else {
              state.errorMessage = "Task must be in backlog to approve";
              wakeAndRender();
            }
            return;
          }
          if (key === "r" || key === "R") {
            if (task.status === "failed" || task.status === "stuck" || task.status === "conflict") {
              void retryTask(task.id, projectPath).then((ok) => {
                if (!ok) {
                  state.errorMessage = "Failed to retry task";
                }
                wakeAndRender();
              });
            } else {
              state.errorMessage = "Task must be failed or stuck to retry";
              wakeAndRender();
            }
            return;
          }
        }
      }

      if (result.wake) {
        wakeAndRender();
      } else if (result.render) {
        const display = renderWatch(state);
        process.stdout.write("\x1B[2J\x1B[H" + display + "\n");
      }
    };

    if (process.stdin.isTTY) {
      try {
        process.stdin.setRawMode(true);
        process.stdin.resume();
        process.stdin.setEncoding("utf8");
        process.stdin.on("data", handleKey);
        stdinRawMode = true;
      } catch {
        // Continue without keyboard handling
      }
    }

    try {
      // ── One-shot mode ─────────────────────────────────────────────────
      if (noWatch) {
        const pollStart = Date.now();
        const result = await pollWatchData(projectPath, projectId);
        state.lastPollMs = pollStart;
        state.dashboard = result.dashboard;
        state.agents = result.agents;
        state.board = result.board;
        state.taskCounts = result.taskCounts;

        if (!noInbox) {
          const runIds = result.agents.map(e => e.run.id);
          const inboxResult = await pollInboxData(store!, null, inboxLimit, runIds, projectPath, projectId);
          state.inbox = {
            messages: inboxResult.messages,
            totalCount: inboxResult.totalCount,
            newestTimestamp: inboxResult.messages[0]?.message.created_at ?? null,
            oldestTimestamp: inboxResult.messages[inboxResult.messages.length - 1]?.message.created_at ?? null,
          };
        }

        // One-shot: poll pipeline events
        if (!noEvents) {
          const runIds = result.agents.map(e => e.run.id);
          const eventsResult = await pollPipelineEvents(store!, null, eventsLimit, runIds, projectPath, projectId);
          state.events = {
            events: eventsResult.events,
            totalCount: eventsResult.totalCount,
            newestTimestamp: eventsResult.events[0]?.createdAt ?? null,
            oldestTimestamp: eventsResult.events[eventsResult.events.length - 1]?.createdAt ?? null,
          };
        }

        console.log(renderWatch(state));
          store?.close();
          return;
      }

      // ── Live mode ─────────────────────────────────────────────────────
      // Determine which panels are visible
      const visiblePanels = {
        agents: true,
        board: !noBoard,
        inbox: !noInbox,
      };

      // Initial poll
      {
        const pollStart = Date.now();
        const result = await pollWatchData(projectPath, projectId);
        state.lastPollMs = pollStart;
        state.dashboard = result.dashboard;
        state.agents = result.agents;
        state.board = result.board;
        state.taskCounts = result.taskCounts;
      }

      // Initial inbox poll
      if (!noInbox) {
        const runIds = state.agents.map(e => e.run.id);
          const inboxResult = await pollInboxData(store!, null, inboxLimit, runIds, projectPath, projectId);
        state.inbox = {
          messages: inboxResult.messages,
          totalCount: inboxResult.totalCount,
          newestTimestamp: inboxResult.messages[0]?.message.created_at ?? null,
          oldestTimestamp: inboxResult.messages[inboxResult.messages.length - 1]?.message.created_at ?? null,
        };
        state.inboxLastSeenId = inboxResult.newestId;
      }

      // Initial events poll
      if (!noEvents) {
        const runIds = state.agents.map(e => e.run.id);
        const eventsResult = await pollPipelineEvents(store!, null, eventsLimit, runIds, projectPath, projectId);
        state.events = {
          events: eventsResult.events,
          totalCount: eventsResult.totalCount,
          newestTimestamp: eventsResult.events[0]?.createdAt ?? null,
          oldestTimestamp: eventsResult.events[eventsResult.events.length - 1]?.createdAt ?? null,
        };
        state.eventsLastSeenId = eventsResult.newestId;
      }

      // Main poll loop
      while (!detached) {
        // Handle SIGWINCH
        if (winchOccurred) {
          winchOccurred = false;
        }

        // Render current state
        const display = renderWatch(state);
        process.stdout.write("\x1B[2J\x1B[H" + display + "\n");

        // Determine sleep timeout:
        // inbox sleeps shorter, main poll sleeps longer
        // We use a single sleep with the inbox interval; on wake, check
        // whether it's a full poll or just an inbox poll.
        await new Promise<void>((resolve) => {
          sleepResolve = resolve;
          setTimeout(resolve, refreshMs);
        });
        sleepResolve = null;

        if (detached) break;

        // Full data poll
        const pollStart = Date.now();
          const result = await pollWatchData(projectPath, projectId);
        state.lastPollMs = pollStart;
        state.dashboard = result.dashboard;
        state.agents = result.agents;
        state.board = result.board;
        state.taskCounts = result.taskCounts;

        // Clear error after a successful poll
        state.errorMessage = null;

        // Inbox-only fast poll
        if (!noInbox) {
          const runIds = result.agents.map(e => e.run.id);
          const inboxResult = await pollInboxData(store!, state.inboxLastSeenId, inboxLimit, runIds, projectPath, projectId);

          if (inboxResult.messages.length > 0) {
            // Prepend new messages (they come in reverse chronological order)
            const existingMessages = state.inbox?.messages ?? [];
            // Mark all incoming as "new" if they're new since lastSeenId
            const newEntries = inboxResult.messages.map((entry, i) => ({
              ...entry,
              isNew: state.inboxLastSeenId !== null && entry.message.id !== state.inboxLastSeenId,
            }));

            // Merge: new entries at top, capped at inboxLimit total
            const merged = [...newEntries, ...existingMessages].slice(0, inboxLimit);

            state.inbox = {
              messages: merged,
              totalCount: inboxResult.totalCount,
              newestTimestamp: newEntries[0]?.message.created_at ?? state.inbox?.newestTimestamp ?? null,
              oldestTimestamp: merged[merged.length - 1]?.message.created_at ?? null,
            };
          }

          // Update last seen
          if (inboxResult.newestId) {
            state.inboxLastSeenId = inboxResult.newestId;
          }
        }

        // Events fast poll
        if (!noEvents) {
          const runIds = result.agents.map(e => e.run.id);
          const eventsResult = await pollPipelineEvents(store!, state.eventsLastSeenId, eventsLimit, runIds, projectPath, projectId);

          if (eventsResult.events.length > 0) {
            // Prepend new events (they come in reverse chronological order)
            const existingEvents = state.events?.events ?? [];
            const newEntries = eventsResult.events.map((entry) => ({
              ...entry,
              isNew: state.eventsLastSeenId !== null && entry.id !== state.eventsLastSeenId,
            }));

            // Merge: new entries at top, capped at eventsLimit total
            const merged = [...newEntries, ...existingEvents].slice(0, eventsLimit);

            state.events = {
              events: merged,
              totalCount: eventsResult.totalCount,
              newestTimestamp: newEntries[0]?.createdAt ?? state.events?.newestTimestamp ?? null,
              oldestTimestamp: merged[merged.length - 1]?.createdAt ?? null,
            };
          }

          // Update last seen
          if (eventsResult.newestId) {
            state.eventsLastSeenId = eventsResult.newestId;
          }
        }
      }
    } finally {
      process.stdout.write("\x1b[?25h"); // restore cursor
      process.removeListener("SIGINT", onSigint);
      try { process.stdout.off("resize", onWinch); } catch { /* ignore */ }
      if (stdinRawMode && process.stdin.isTTY) {
        process.stdin.removeListener("data", handleKey);
        try { process.stdin.setRawMode(false); } catch { /* ignore */ }
        process.stdin.pause();
      }
      store?.close();
    }
  });
