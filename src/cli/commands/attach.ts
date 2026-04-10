import { Command } from "commander";
import { spawn } from "node:child_process";
import { join } from "node:path";
import { homedir } from "node:os";
import { ForemanStore, type Run, type RunProgress, type Message } from "../../lib/store.js";

// ── Exported action for testing ─────────────────────────────────────────

export interface AttachOpts {
  list?: boolean;
  follow?: boolean;
  kill?: boolean;
  worktree?: boolean;
  stream?: boolean;
  /** Internal: AbortSignal for follow/stream mode (used by tests) */
  _signal?: AbortSignal;
  /** Internal: poll interval ms for stream mode (used by tests) */
  _pollIntervalMs?: number;
}

const DEGRADED_ATTACH_EXIT_CODE = 2;
const INTERRUPTED_EXIT_CODE = 130;


/**
 * Core attach logic extracted for testability.
 * Returns the exit code (0 = success, 1 = failure, 2 = degraded fallback attach, 130 = interrupted).
 * When called from the CLI command, `projectPath` is `process.cwd()`.
 */
export async function attachAction(
  id: string,
  opts: AttachOpts,
  store: ForemanStore,
  projectPath: string,
): Promise<number> {
  // Look up by run ID first. Seed lookup requires a registered local project row.
  let run = store.getRun(id);
  const project = store.getProjectByPath(projectPath);
  if (!run && project) {
    const runs = store.getRunsForSeed(id, project.id);
    if (runs.length > 0) {
      run = runs[0]; // Most recent
    }
  }

  if (!run) {
    if (!project) {
      console.error("No project registered for this directory. Run 'foreman init' first.");
      return 1;
    }
    console.error(`No run found for "${id}". Use 'foreman attach --list' to see available sessions.`);
    return 1;
  }

  // ── --kill ────────────────────────────────────────────────────────────
  if (opts.kill) {
    return handleKill(run, store);
  }

  // ── --worktree ────────────────────────────────────────────────────────
  if (opts.worktree) {
    return handleWorktree(run);
  }

  // ── --stream ──────────────────────────────────────────────────────────
  if (opts.stream) {
    return handleStream(run, store, opts._signal, opts._pollIntervalMs);
  }

  // ── --follow ──────────────────────────────────────────────────────────
  if (opts.follow) {
    return handleFollow(run, opts._signal);
  }

  // ── Default: tail log file or SDK session resume ──────────────────────
  return handleDefaultAttach(run);
}

/**
 * Enhanced session listing with richer columns.
 */
export function listSessionsEnhanced(store: ForemanStore, projectPath: string): number {
  const project = store.getProjectByPath(projectPath);
  if (!project) {
    console.error("No project registered for this directory. Run 'foreman init' first.");
    return 1;
  }

  const statuses = ["running", "stuck", "failed", "completed"] as const;
  const allRuns = statuses.flatMap((s) => store.getRunsByStatus(s, project.id));

  if (allRuns.length === 0) {
    console.log("No sessions found.");
    return 0;
  }

  // Sort by status priority then recency
  const statusPriority: Record<string, number> = {
    running: 0,
    pending: 0,
    stuck: 1,
    failed: 2,
    "test-failed": 2,
    conflict: 2,
    completed: 3,
    merged: 3,
    "pr-created": 3,
  };

  const sorted = [...allRuns].sort((a, b) => {
    const pa = statusPriority[a.status] ?? 4;
    const pb = statusPriority[b.status] ?? 4;
    if (pa !== pb) return pa - pb;
    // Within same status, most recent first
    const ta = a.started_at ?? a.created_at;
    const tb = b.started_at ?? b.created_at;
    return tb.localeCompare(ta);
  });

  console.log("Attachable sessions:\n");
  console.log(
    "  " +
    "SEED".padEnd(22) +
    "STATUS".padEnd(12) +
    "PHASE".padEnd(12) +
    "PROGRESS".padEnd(20) +
    "COST".padEnd(10) +
    "ELAPSED".padEnd(12) +
    "WORKTREE",
  );
  console.log("  " + "\u2500".repeat(106));

  for (const run of sorted) {
    const progress = parseProgress(run.progress);
    const phase = progress?.currentPhase ?? "-";
    const progressStr = progress
      ? `${progress.toolCalls} tools, ${progress.filesChanged.length} files`
      : "-";
    const cost = progress ? `$${progress.costUsd.toFixed(2)}` : "-";
    const elapsed = formatElapsed(run.started_at);
    const worktree = run.worktree_path ?? "-";

    console.log(
      "  " +
      run.seed_id.padEnd(22) +
      run.status.padEnd(12) +
      phase.padEnd(12) +
      progressStr.padEnd(20) +
      cost.padEnd(10) +
      elapsed.padEnd(12) +
      worktree,
    );
  }
  console.log();
  return 0;
}

// ── Internal handlers ─────────────────────────────────────────────────

async function handleDefaultAttach(run: Run): Promise<number> {
  // Try SDK session resume
  const sessionId = extractSessionId(run.session_key);
  if (sessionId) {
    console.error(`Attaching to ${run.seed_id} [${run.agent_type}] session=${sessionId}`);
    console.error(`  Status: ${run.status}`);
    if (run.worktree_path) {
      console.error(`  Worktree: ${run.worktree_path}`);
    }
    console.error();

    return new Promise<number>((resolve) => {
      const child = spawn("claude", ["--resume", sessionId], {
        cwd: run.worktree_path ?? process.cwd(),
        stdio: "inherit",
      });

      child.on("error", (err) => {
        console.error(`Failed to launch claude: ${err.message}`);
        console.error("Ensure 'claude' CLI is installed and in your PATH.");
        resolve(1);
      });

      child.on("exit", (code) => {
        resolve(code ?? 0);
      });
    });
  }

  // Tail the log file as a fallback. This is useful, but it is not a true session attach.
  const logPath = join(homedir(), ".foreman", "logs", `${run.id}.out`);
  console.error(`No resumable SDK session found for ${run.seed_id}; falling back to log tailing.`);
  console.error(`  Log: ${logPath}`);
  console.error("  This follows agent stdout only; it does not resume the original Claude session.");
  console.error("  Press Ctrl+C to stop.\n");

  return new Promise<number>((resolve) => {
    const child = spawn("tail", ["-f", logPath], { stdio: "inherit" });

    child.on("error", (err) => {
      console.error(`Failed to tail log file: ${err.message}`);
      console.error(`No active session found for "${run.seed_id}". The agent may have completed or crashed.`);
      resolve(1);
    });

    child.on("exit", (code) => {
      resolve(code === 0 ? DEGRADED_ATTACH_EXIT_CODE : (code ?? DEGRADED_ATTACH_EXIT_CODE));
    });
  });
}

async function handleFollow(
  run: Run,
  signal?: AbortSignal,
): Promise<number> {
  // Tail log file
  const logPath = join(homedir(), ".foreman", "logs", `${run.id}.out`);
  console.error(`Following log for ${run.seed_id} [${run.agent_type}] | Ctrl+C to stop`);
  console.error(`Log: ${logPath}\n`);

  return new Promise<number>((resolve) => {
    let interrupted = false;
    const child = spawn("tail", ["-f", logPath], { stdio: "inherit" });

    const abortHandler = () => {
      interrupted = true;
      console.error("\nFollow interrupted before the run reached a terminal state.");
      child.kill("SIGTERM");
    };

    if (signal) {
      signal.addEventListener("abort", abortHandler, { once: true });
      if (signal.aborted) abortHandler();
    }

    child.on("error", (err) => {
      if (signal) signal.removeEventListener("abort", abortHandler);
      console.error(`Failed to tail log file: ${err.message}`);
      resolve(1);
    });

    child.on("exit", (code) => {
      if (signal) signal.removeEventListener("abort", abortHandler);
      resolve(interrupted ? INTERRUPTED_EXIT_CODE : (code ?? 0));
    });
  });
}

/**
 * Stream mode: polls Agent Mail messages for the run and prints them as they arrive.
 * Continues until the run reaches a terminal state or the signal fires.
 * This is the post-tmux replacement for tmux capture-pane streaming.
 */
async function handleStream(
  run: Run,
  store: ForemanStore,
  signal?: AbortSignal,
  pollIntervalMs = 1000,
): Promise<number> {
  const terminalStatuses = new Set(["completed", "failed", "stuck", "merged", "conflict", "test-failed", "pr-created"]);

  console.error(`Streaming agent mail for ${run.seed_id} [${run.id}] | Ctrl+C to stop`);
  console.error(`  Status: ${run.status}`);
  if (run.worktree_path) {
    console.error(`  Worktree: ${run.worktree_path}`);
  }
  console.error();

  const seenIds = new Set<string>();

  // Print any existing messages first
  const existing = store.getAllMessages(run.id);
  for (const msg of existing) {
    seenIds.add(msg.id);
    printMessage(msg);
  }

  // If already in terminal state, we're done
  const currentRun = store.getRun(run.id);
  if (currentRun && terminalStatuses.has(currentRun.status)) {
    console.error(`\nRun ${run.seed_id} is already ${currentRun.status}.`);
    return 0;
  }

  return new Promise<number>((resolve) => {
    let intervalId: ReturnType<typeof setInterval> | null = null;
    let resolved = false;
    let interrupted = false;

    const abortHandler = () => {
      interrupted = true;
      console.error("\nStream interrupted before the run reached a terminal state.");
      cleanup(INTERRUPTED_EXIT_CODE);
    };

    const cleanup = (code: number) => {
      if (resolved) return;
      resolved = true;
      if (signal) signal.removeEventListener("abort", abortHandler);
      if (intervalId !== null) {
        clearInterval(intervalId);
        intervalId = null;
      }
      resolve(code);
    };

    const poll = () => {
      // Check for new messages
      const messages = store.getAllMessages(run.id);
      for (const msg of messages) {
        if (!seenIds.has(msg.id)) {
          seenIds.add(msg.id);
          printMessage(msg);
        }
      }

      // Check if run has reached terminal state
      const latestRun = store.getRun(run.id);
      if (latestRun && terminalStatuses.has(latestRun.status)) {
        console.error(`\nRun ${run.seed_id} reached terminal state: ${latestRun.status}`);
        cleanup(0);
      }
    };

    intervalId = setInterval(poll, pollIntervalMs);

    if (signal) {
      signal.addEventListener("abort", abortHandler, { once: true });
      if (signal.aborted && !interrupted) abortHandler();
    }
  });
}

/**
 * Format and print a single Agent Mail message to stdout.
 */
function printMessage(msg: Message): void {
  const ts = new Date(msg.created_at).toLocaleTimeString();
  const from = msg.sender_agent_type.padEnd(12);
  const to = msg.recipient_agent_type.padEnd(12);
  const subject = msg.subject;

  // Summarise body: parse JSON if possible, else truncate
  let bodySummary = "";
  try {
    const parsed = JSON.parse(msg.body) as Record<string, unknown>;
    const parts: string[] = [];
    if (typeof parsed["phase"] === "string") parts.push(`phase=${parsed["phase"]}`);
    if (typeof parsed["status"] === "string") parts.push(`status=${parsed["status"]}`);
    if (typeof parsed["error"] === "string") parts.push(`error=${parsed["error"]}`);
    if (typeof parsed["currentPhase"] === "string") parts.push(`currentPhase=${parsed["currentPhase"]}`);
    bodySummary = parts.length > 0 ? parts.join(", ") : msg.body.slice(0, 80);
  } catch {
    bodySummary = msg.body.slice(0, 80);
  }

  console.log(`  [${ts}] ${from} → ${to} | ${subject}: ${bodySummary}`);
}

async function handleKill(run: Run, store: ForemanStore): Promise<number> {
  const pid = extractPid(run.session_key);
  if (!pid) {
    console.error(`Cannot kill run ${run.seed_id}: no pid is recorded for this run.`);
    return 1;
  }

  try {
    process.kill(pid, "SIGTERM");
    console.log(`Sent SIGTERM to pid ${pid}`);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`Failed to kill pid ${pid}: ${msg}`);
    return 1;
  }

  // Mark active runs as stuck
  if (run.status === "running" || run.status === "pending") {
    store.updateRun(run.id, { status: "stuck" });
  }

  return 0;
}

function handleWorktree(run: Run): Promise<number> {
  if (!run.worktree_path) {
    console.error(`Run ${run.id} has no worktree path.`);
    return Promise.resolve(1);
  }

  const worktreePath = run.worktree_path;
  console.error(`Opening interactive shell in ${worktreePath}`);
  const shell = process.env.SHELL ?? "/bin/bash";

  return new Promise<number>((resolve) => {
    const child = spawn(shell, [], {
      cwd: worktreePath,
      stdio: "inherit" as const,
    });
    child.on("error", (err: Error) => {
      console.error(`Failed to launch shell ${shell}: ${err.message}`);
      resolve(1);
    });
    child.on("exit", (code: number | null) => resolve(code ?? 0));
  });
}

// ── Utility functions ─────────────────────────────────────────────────

function extractSessionId(sessionKey: string | null): string | null {
  if (!sessionKey) return null;
  const m = sessionKey.match(/session-(.+)$/);
  return m ? m[1] : null;
}

function extractPid(sessionKey: string | null): number | null {
  if (!sessionKey) return null;
  const m = sessionKey.match(/pid-(\d+)/);
  return m ? parseInt(m[1], 10) : null;
}

function parseProgress(progressJson: string | null): RunProgress | null {
  if (!progressJson) return null;
  try {
    return JSON.parse(progressJson) as RunProgress;
  } catch {
    return null;
  }
}

function formatElapsed(startedAt: string | null): string {
  if (!startedAt) return "-";
  const start = new Date(startedAt).getTime();
  const now = Date.now();
  const diffMs = now - start;
  if (diffMs < 0) return "-";

  const totalMinutes = Math.floor(diffMs / 60000);
  if (totalMinutes < 60) {
    return `${totalMinutes}m`;
  }
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  return `${hours}h ${minutes}m`;
}

// ── CLI Command ─────────────────────────────────────────────────────────

export const attachCommand = new Command("attach")
  .description("Attach to a running or completed agent's Claude session")
  .argument("[id]", "Run ID or bead ID to attach to")
  .option("--list", "List all attachable sessions")
  .option("--follow", "Follow agent log file in real-time (tail -f)")
  .option("--stream", "Stream Agent Mail messages for the run in real-time")
  .option("--kill", "Kill the agent process for this run")
  .option("--worktree", "Open a shell in the agent's worktree instead of attaching")
  .action(async (id: string | undefined, opts: AttachOpts) => {
    const store = ForemanStore.forProject(process.cwd());

    if (opts.list) {
      const exitCode = listSessionsEnhanced(store, process.cwd());
      store.close();
      process.exit(exitCode);
    }

    if (!id) {
      console.error("Usage: foreman attach <run-id|bead-id>");
      console.error("       foreman attach --list");
      console.error("       foreman attach --follow <id>");
      console.error("       foreman attach --stream <id>");
      console.error("       foreman attach --kill <id>");
      console.error("       foreman attach --worktree <id>");
      store.close();
      process.exit(1);
    }

    const exitCode = await attachAction(id, opts, store, process.cwd());
    store.close();
    process.exit(exitCode);
  });
