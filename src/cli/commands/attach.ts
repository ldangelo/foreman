import { Command } from "commander";
import { spawn, spawnSync } from "node:child_process";
import { join } from "node:path";
import { homedir } from "node:os";
import { ForemanStore, type Run, type RunProgress } from "../../lib/store.js";
import { TmuxClient } from "../../lib/tmux.js";

// ── Exported action for testing ─────────────────────────────────────────

export interface AttachOpts {
  list?: boolean;
  follow?: boolean;
  kill?: boolean;
  worktree?: boolean;
  /** Internal: AbortSignal for follow mode (used by tests) */
  _signal?: AbortSignal;
}

/**
 * Core attach logic extracted for testability.
 * Returns the exit code (0 = success, 1 = error).
 * When called from the CLI command, `projectPath` is `process.cwd()`.
 */
export async function attachAction(
  id: string,
  opts: AttachOpts,
  store: ForemanStore,
  projectPath: string,
): Promise<number> {
  const tmux = new TmuxClient();

  // Look up by run ID first, then by seed ID (most recent run)
  let run = store.getRun(id);
  if (!run) {
    const project = store.getProjectByPath(projectPath);
    if (project) {
      const runs = store.getRunsForSeed(id, project.id);
      if (runs.length > 0) {
        run = runs[0]; // Most recent
      }
    }
  }

  if (!run) {
    console.error(`No run found for "${id}". Use 'foreman attach --list' to see available sessions.`);
    return 1;
  }

  // ── --kill ────────────────────────────────────────────────────────────
  if (opts.kill) {
    return handleKill(run, store, tmux);
  }

  // ── --worktree ────────────────────────────────────────────────────────
  if (opts.worktree) {
    return handleWorktree(run);
  }

  // ── --follow ──────────────────────────────────────────────────────────
  if (opts.follow) {
    return handleFollow(run, tmux, opts._signal);
  }

  // ── Default: interactive tmux attach or SDK fallback ──────────────────
  return handleDefaultAttach(run, tmux);
}

/**
 * Enhanced session listing with richer columns.
 */
export function listSessionsEnhanced(store: ForemanStore, projectPath: string): void {
  const project = store.getProjectByPath(projectPath);
  if (!project) {
    console.error("No project registered for this directory. Run 'foreman init' first.");
    return;
  }

  const statuses = ["running", "stuck", "failed", "completed"] as const;
  const allRuns = statuses.flatMap((s) => store.getRunsByStatus(s, project.id));

  if (allRuns.length === 0) {
    console.log("No sessions found.");
    return;
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
    "TMUX".padEnd(24) +
    "WORKTREE",
  );
  console.log("  " + "\u2500".repeat(130));

  for (const run of sorted) {
    const progress = parseProgress(run.progress);
    const phase = progress?.currentPhase ?? "-";
    const progressStr = progress
      ? `${progress.toolCalls} tools, ${progress.filesChanged.length} files`
      : "-";
    const cost = progress ? `$${progress.costUsd.toFixed(2)}` : "-";
    const elapsed = formatElapsed(run.started_at);
    const tmuxName = run.tmux_session ?? "(none)";
    const worktree = run.worktree_path ?? "-";

    console.log(
      "  " +
      run.seed_id.padEnd(22) +
      run.status.padEnd(12) +
      phase.padEnd(12) +
      progressStr.padEnd(20) +
      cost.padEnd(10) +
      elapsed.padEnd(12) +
      tmuxName.padEnd(24) +
      worktree,
    );
  }
  console.log();
}

// ── Internal handlers ─────────────────────────────────────────────────

async function handleDefaultAttach(run: Run, tmux: TmuxClient): Promise<number> {
  // Try tmux attach first
  if (run.tmux_session) {
    const sessionExists = await tmux.hasSession(run.tmux_session);
    if (sessionExists) {
      const progress = parseProgress(run.progress);
      const phase = progress?.currentPhase ?? run.agent_type;
      console.log(`Attaching to ${run.tmux_session} [${phase}] | Ctrl+B, D to detach`);

      const result = spawnSync("tmux", ["attach-session", "-t", run.tmux_session], {
        stdio: "inherit",
      });
      return result.status ?? 0;
    }
  }

  // Fallback to SDK session resume
  const sessionId = extractSessionId(run.session_key);
  if (sessionId) {
    console.log("Tmux session not found. Falling back to SDK session resume.");
    console.log(`Attaching to ${run.seed_id} [${run.agent_type}] session=${sessionId}`);
    console.log(`  Status: ${run.status}`);
    if (run.worktree_path) {
      console.log(`  Worktree: ${run.worktree_path}`);
    }
    console.log();

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

  // Both unavailable
  console.error(`No active session found for "${run.seed_id}". The agent may have completed or crashed.`);
  console.error("Use 'foreman attach --list' to see available sessions.");
  return 1;
}

async function handleFollow(
  run: Run,
  tmux: TmuxClient,
  signal?: AbortSignal,
): Promise<number> {
  // Check if tmux session is available
  const hasTmux = run.tmux_session
    ? await tmux.hasSession(run.tmux_session)
    : false;

  if (!hasTmux || !run.tmux_session) {
    // Fallback to tailing log file
    console.log("No tmux session for this run. Tailing log file instead.");
    const logPath = join(homedir(), ".foreman", "logs", `${run.id}.out`);

    return new Promise<number>((resolve) => {
      const child = spawn("tail", ["-f", logPath], { stdio: "inherit" });

      child.on("error", (err) => {
        console.error(`Failed to tail log file: ${err.message}`);
        resolve(1);
      });

      child.on("exit", (code) => {
        resolve(code ?? 0);
      });
    });
  }

  // Follow mode with tmux capture-pane polling
  const progress = parseProgress(run.progress);
  const phase = progress?.currentPhase ?? run.agent_type;
  console.log(
    `Following ${run.tmux_session} [${phase}] | Ctrl+C to stop | foreman attach ${run.seed_id} for interactive`,
  );

  const intervalMs = parseInt(
    process.env.FOREMAN_TMUX_FOLLOW_INTERVAL_MS ?? "1000",
    10,
  );

  let previousLineCount = 0;
  let aborted = false;

  // Set up signal handling
  const abortHandler = () => {
    aborted = true;
  };

  if (signal) {
    signal.addEventListener("abort", abortHandler);
  }

  return new Promise<number>((resolve) => {
    const poll = async () => {
      if (aborted) {
        console.log("\nStopped following. Agent continues running.");
        if (signal) signal.removeEventListener("abort", abortHandler);
        resolve(0);
        return;
      }

      // Check if session still exists
      const stillAlive = await tmux.hasSession(run.tmux_session!);
      if (!stillAlive) {
        console.log("Session ended.");
        if (signal) signal.removeEventListener("abort", abortHandler);
        resolve(0);
        return;
      }

      // Capture output and print new lines
      const lines = await tmux.capturePaneOutput(run.tmux_session!);
      if (lines.length > previousLineCount) {
        for (let i = previousLineCount; i < lines.length; i++) {
          console.log(lines[i]);
        }
        previousLineCount = lines.length;
      }

      // Schedule next poll
      setTimeout(() => {
        poll().catch(() => resolve(1));
      }, intervalMs);
    };

    poll().catch(() => resolve(1));
  });
}

async function handleKill(run: Run, store: ForemanStore, tmux: TmuxClient): Promise<number> {
  if (!run.tmux_session) {
    console.log("No tmux session to kill for this run.");
    return 0;
  }

  await tmux.killSession(run.tmux_session);
  console.log(`Killed tmux session ${run.tmux_session}`);

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

  console.log(`Opening shell in ${run.worktree_path}`);
  const shell = process.env.SHELL ?? "/bin/bash";

  return new Promise<number>((resolve) => {
    spawn(shell, [], {
      cwd: run.worktree_path!,
      stdio: "inherit",
    }).on("exit", (code) => resolve(code ?? 0));
  });
}

// ── Utility functions ─────────────────────────────────────────────────

function extractSessionId(sessionKey: string | null): string | null {
  if (!sessionKey) return null;
  const m = sessionKey.match(/session-(.+)$/);
  return m ? m[1] : null;
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
  .argument("[id]", "Run ID or seed ID to attach to")
  .option("--list", "List all attachable sessions")
  .option("--follow", "Read-only follow mode via capture-pane polling")
  .option("--kill", "Kill the tmux session for this run")
  .option("--worktree", "Open a shell in the agent's worktree instead of attaching")
  .action(async (id: string | undefined, opts: AttachOpts) => {
    const store = ForemanStore.forProject(process.cwd());

    if (opts.list) {
      listSessionsEnhanced(store, process.cwd());
      store.close();
      return;
    }

    if (!id) {
      console.error("Usage: foreman attach <run-id|seed-id>");
      console.error("       foreman attach --list");
      console.error("       foreman attach --follow <id>");
      console.error("       foreman attach --kill <id>");
      store.close();
      process.exit(1);
    }

    const exitCode = await attachAction(id, opts, store, process.cwd());
    store.close();
    process.exit(exitCode);
  });
