import { Command } from "commander";
import { spawn } from "node:child_process";
import { join } from "node:path";
import { homedir } from "node:os";
import { ForemanStore, type Run, type RunProgress, type Message } from "../../lib/store.js";
import { createTrpcClient } from "../../lib/trpc-client.js";
import { ElixirServerClient, type ElixirInboxMessage, type ElixirRun } from "../../lib/elixir-server-client.js";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";
import { foremanBackendMode } from "../../lib/backend-mode.js";
import { resolveRepoRootProjectPath, listRegisteredProjects } from "./project-task-support.js";
import { getWorkspacePath } from "../../lib/workspace-paths.js";

interface DaemonRunRow {
  id: string;
  project_id: string;
  bead_id: string;
  status: string;
  branch: string;
  agent_type: string | null;
  session_key: string | null;
  worktree_path: string | null;
  progress: string | null;
  base_branch: string | null;
  merge_strategy: string | null;
  queued_at: string;
  started_at: string | null;
  finished_at: string | null;
  created_at: string;
}

interface DaemonAttachContext {
  client: ReturnType<typeof createTrpcClient>;
  projectId: string;
  projectPath: string;
}

interface ElixirAttachContext {
  client: ElixirServerClient;
  projectId: string;
  projectPath: string;
}

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

function adaptDaemonRun(row: DaemonRunRow, projectPath: string): Run {
  const statusMap: Record<string, Run["status"]> = {
    pending: "pending",
    running: "running",
    success: "completed",
    failure: "failed",
    cancelled: "reset",
    skipped: "reset",
  };
  return {
    id: row.id,
    project_id: row.project_id,
    seed_id: row.bead_id,
    agent_type: row.agent_type ?? "daemon",
    session_key: row.session_key,
    worktree_path: row.worktree_path ?? getWorkspacePath(projectPath, row.bead_id),
    status: statusMap[row.status] ?? "failed",
    started_at: row.started_at,
    completed_at: row.finished_at,
    created_at: row.created_at,
    progress: row.progress,
    base_branch: row.base_branch,
    merge_strategy: (row.merge_strategy as Run["merge_strategy"]) ?? null,
  };
}

async function resolveDaemonAttachContext(projectPath: string): Promise<DaemonAttachContext | null> {
  if (foremanBackendMode() === "elixir") return null;
  try {
    const projects = await listRegisteredProjects();
    const project = projects.find((record) => record.path === projectPath);
    if (!project) return null;
    return {
      client: createTrpcClient(),
      projectId: project.id,
      projectPath,
    };
  } catch {
    return null;
  }
}

async function resolveElixirAttachContext(projectPath: string): Promise<ElixirAttachContext | null> {
  if (foremanBackendMode() !== "elixir") return null;
  try {
    const projects = await listRegisteredProjects();
    const project = projects.find((record) => record.path === projectPath);
    if (!project) throw new Error(`Project '${projectPath}' not found in Elixir project registry; refusing legacy daemon/local attach fallback. Set FOREMAN_BACKEND=node for legacy attach.`);
    const manager = new ElixirServerManager();
    const status = await manager.ensureRunning();
    return {
      client: new ElixirServerClient(status.url, manager.authToken),
      projectId: project.id,
      projectPath,
    };
  } catch (err) {
    if (foremanBackendMode() === "elixir") throw err;
    return null;
  }
}

async function resolveDaemonRun(context: DaemonAttachContext, id: string): Promise<Run | null> {
  const runs = await context.client.runs.list({ projectId: context.projectId, limit: 100 }) as DaemonRunRow[];
  const row = runs.find((run) => run.id === id || run.id.startsWith(id) || run.bead_id === id);
  return row ? adaptDaemonRun(row, context.projectPath) : null;
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

function adaptElixirRun(row: ElixirRun, projectPath: string): Run {
  const runId = String(row.run_id ?? row.id ?? "");
  const taskId = typeof row.task_id === "string" ? row.task_id : runId;
  return {
    id: runId,
    project_id: typeof row.project_id === "string" ? row.project_id : "",
    seed_id: taskId,
    agent_type: typeof row.agent_type === "string" ? row.agent_type : "elixir",
    session_key: typeof row.session_key === "string" ? row.session_key : null,
    worktree_path: typeof row.worktree_path === "string" ? row.worktree_path : getWorkspacePath(projectPath, taskId),
    status: normalizeRunStatus(row.status),
    started_at: typeof row.started_at === "string" ? row.started_at : null,
    completed_at: typeof row.finished_at === "string" ? row.finished_at : null,
    created_at: typeof row.created_at === "string" ? row.created_at : new Date(0).toISOString(),
    progress: typeof row.progress === "string" ? row.progress : null,
    base_branch: typeof row.base_branch === "string" ? row.base_branch : null,
    merge_strategy: null,
  };
}

function adaptElixirMessage(row: ElixirInboxMessage): Message {
  const body = typeof row.body === "string" ? row.body : JSON.stringify(row);
  return {
    id: String(row.message_id ?? row.id ?? `${row.run_id ?? "run"}-${row.created_at ?? Date.now()}`),
    run_id: String(row.run_id ?? ""),
    sender_agent_type: typeof row.sender_agent_type === "string" ? row.sender_agent_type : String(row.sender ?? "agent"),
    recipient_agent_type: typeof row.recipient_agent_type === "string" ? row.recipient_agent_type : String(row.recipient ?? "foreman"),
    subject: typeof row.subject === "string" ? row.subject : String(row.event_type ?? "message"),
    body,
    read: row.unread === true ? 0 : 1,
    created_at: typeof row.created_at === "string" ? row.created_at : new Date().toISOString(),
    deleted_at: null,
  };
}

function normalizeRunStatus(status: unknown): Run["status"] {
  const value = typeof status === "string" ? status : "pending";
  const statusMap: Record<string, Run["status"]> = {
    pending: "pending",
    queued: "pending",
    in_progress: "running",
    running: "running",
    success: "completed",
    completed: "completed",
    failure: "failed",
    failed: "failed",
    blocked: "stuck",
    stuck: "stuck",
    cancelled: "reset",
    canceled: "reset",
    reset: "reset",
    merged: "merged",
    conflict: "conflict",
  };
  return statusMap[value] ?? "failed";
}

async function resolveElixirRun(context: ElixirAttachContext, id: string): Promise<Run | null> {
  const runs = await context.client.listRuns(context.projectId);
  const row = runs.find((run) => {
    const runId = String(run.run_id ?? run.id ?? "");
    return runId === id || runId.startsWith(id) || run.task_id === id;
  });
  return row ? adaptElixirRun(row, context.projectPath) : null;
}

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
  daemon?: DaemonAttachContext | null,
): Promise<number> {
  // Look up by run ID first, then by seed ID (most recent run)
  let run = store.getRun(id);
  let daemonRun: Run | null = null;
  if (!run) {
    const project = store.getProjectByPath(projectPath);
    if (project) {
      const runs = store.getRunsForSeed(id, project.id);
      if (runs.length > 0) {
        run = runs[0]; // Most recent
      }
    }
  }

  if (opts.kill && daemon) {
    try {
      daemonRun = await resolveDaemonRun(daemon, id);
      if (!run && daemonRun) {
        run = daemonRun;
      }
    } catch {
      // Fall through to the existing local lookup error / fallback path.
    }
  }

  if (!run) {
    console.error(`No run found for "${id}". Use 'foreman attach --list' to see available sessions.`);
    return 1;
  }

  // ── --kill ────────────────────────────────────────────────────────────
  if (opts.kill) {
    if (daemon && daemonRun) {
      return handleKillDaemon(daemonRun, daemon, store, run);
    }

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
}

export async function listSessionsEnhancedDaemon(context: DaemonAttachContext): Promise<void> {
  const rows = await context.client.runs.list({ projectId: context.projectId, limit: 100 }) as DaemonRunRow[];
  listRunRows(rows.map((row) => adaptDaemonRun(row, context.projectPath)));
}

export async function listSessionsEnhancedElixir(context: ElixirAttachContext): Promise<void> {
  const rows = await context.client.listRuns(context.projectId);
  listRunRows(rows.map((row) => adaptElixirRun(row, context.projectPath)));
}

function listRunRows(allRuns: Run[]): void {
  if (allRuns.length === 0) {
    console.log("No sessions found.");
    return;
  }

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
  console.log("  " + "─".repeat(106));

  for (const run of sorted) {
    const elapsed = formatElapsed(run.started_at);
    const worktree = run.worktree_path ?? "-";
    console.log(
      "  " +
      run.seed_id.padEnd(22) +
      run.status.padEnd(12) +
      "-".padEnd(12) +
      "-".padEnd(20) +
      "-".padEnd(10) +
      elapsed.padEnd(12) +
      worktree,
    );
  }
  console.log();
}

// ── Internal handlers ─────────────────────────────────────────────────

async function handleDefaultAttach(run: Run): Promise<number> {
  // Try SDK session resume
  const sessionId = extractSessionId(run.session_key);
  if (sessionId) {
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

  // Tail the log file as a fallback
  const logPath = join(homedir(), ".foreman", "logs", `${run.id}.out`);
  console.log(`No SDK session found. Tailing log file: ${logPath}`);
  console.log("Press Ctrl+C to stop.\n");

  return new Promise<number>((resolve) => {
    const child = spawn("tail", ["-f", logPath], { stdio: "inherit" });

    child.on("error", (err) => {
      console.error(`Failed to tail log file: ${err.message}`);
      console.error(`No active session found for "${run.seed_id}". The agent may have completed or crashed.`);
      resolve(1);
    });

    child.on("exit", (code) => {
      resolve(code ?? 0);
    });
  });
}

async function handleFollow(
  run: Run,
  signal?: AbortSignal,
): Promise<number> {
  // Tail log file
  const logPath = join(homedir(), ".foreman", "logs", `${run.id}.out`);
  console.log(`Following log for ${run.seed_id} [${run.agent_type}] | Ctrl+C to stop`);
  console.log(`Log: ${logPath}\n`);

  return new Promise<number>((resolve) => {
    const child = spawn("tail", ["-f", logPath], { stdio: "inherit" });

    const abortHandler = () => {
      child.kill("SIGTERM");
    };

    if (signal) {
      signal.addEventListener("abort", abortHandler);
    }

    child.on("error", (err) => {
      if (signal) signal.removeEventListener("abort", abortHandler);
      console.error(`Failed to tail log file: ${err.message}`);
      resolve(1);
    });

    child.on("exit", (code) => {
      if (signal) signal.removeEventListener("abort", abortHandler);
      resolve(code ?? 0);
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

  console.log(`Streaming agent mail for ${run.seed_id} [${run.id}] | Ctrl+C to stop`);
  console.log(`  Status: ${run.status}`);
  if (run.worktree_path) {
    console.log(`  Worktree: ${run.worktree_path}`);
  }
  console.log();

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
    console.log(`\nRun ${run.seed_id} is already ${currentRun.status}.`);
    return 0;
  }

  return new Promise<number>((resolve) => {
    let intervalId: ReturnType<typeof setInterval> | null = null;
    let resolved = false;

    const cleanup = (code: number) => {
      if (resolved) return;
      resolved = true;
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
        console.log(`\nRun ${run.seed_id} reached terminal state: ${latestRun.status}`);
        cleanup(0);
      }
    };

    intervalId = setInterval(poll, pollIntervalMs);

    if (signal) {
      signal.addEventListener("abort", () => {
        console.log("\nStream interrupted.");
        cleanup(0);
      });
    }
  });
}

async function handleStreamDaemon(
  run: Run,
  context: DaemonAttachContext,
  signal?: AbortSignal,
  pollIntervalMs = 1000,
): Promise<number> {
  return handleStreamRemote(
    run,
    signal,
    pollIntervalMs,
    async () => (await context.client.mail.list({ projectId: context.projectId, runId: run.id }) as DaemonMailMessage[]).map(adaptDaemonMessage),
    async () => {
      const latest = await context.client.runs.get({ runId: run.id }) as DaemonRunRow | null;
      return latest ? adaptDaemonRun(latest, context.projectPath).status : null;
    },
  );
}

async function handleStreamElixir(
  run: Run,
  context: ElixirAttachContext,
  signal?: AbortSignal,
  pollIntervalMs = 1000,
): Promise<number> {
  return handleStreamRemote(
    run,
    signal,
    pollIntervalMs,
    async () => (await context.client.listInbox({ projectId: context.projectId, runId: run.id })).map(adaptElixirMessage),
    async () => (await resolveElixirRun(context, run.id))?.status ?? null,
  );
}

async function handleStreamRemote(
  run: Run,
  signal: AbortSignal | undefined,
  pollIntervalMs: number,
  listMessages: () => Promise<Message[]>,
  getStatus: () => Promise<Run["status"] | null>,
): Promise<number> {
  const terminalStatuses = new Set(["completed", "failed", "stuck", "merged", "conflict", "test-failed", "pr-created", "reset"]);

  console.log(`Streaming agent mail for ${run.seed_id} [${run.id}] | Ctrl+C to stop`);
  console.log(`  Status: ${run.status}`);
  if (run.worktree_path) {
    console.log(`  Worktree: ${run.worktree_path}`);
  }
  console.log();

  const seenIds = new Set<string>();
  for (const msg of await listMessages()) {
    seenIds.add(msg.id);
    printMessage(msg);
  }

  const currentStatus = await getStatus();
  if (currentStatus && terminalStatuses.has(currentStatus)) {
    console.log(`\nRun ${run.seed_id} is already ${currentStatus}.`);
    return 0;
  }

  return new Promise<number>((resolve) => {
    let intervalId: ReturnType<typeof setInterval> | null = null;
    let resolved = false;

    const cleanup = (code: number) => {
      if (resolved) return;
      resolved = true;
      if (intervalId !== null) {
        clearInterval(intervalId);
        intervalId = null;
      }
      resolve(code);
    };

    const poll = () => {
      void (async () => {
        for (const msg of await listMessages()) {
          if (!seenIds.has(msg.id)) {
            seenIds.add(msg.id);
            printMessage(msg);
          }
        }

        const latestStatus = await getStatus();
        if (latestStatus && terminalStatuses.has(latestStatus)) {
          console.log(`\nRun ${run.seed_id} reached terminal state: ${latestStatus}`);
          cleanup(0);
        }
      })().catch(() => undefined);
    };

    intervalId = setInterval(poll, pollIntervalMs);

    if (signal) {
      signal.addEventListener("abort", () => {
        console.log("\nStream interrupted.");
        cleanup(0);
      });
    }
  });
}

async function handleDefaultAttachElixir(run: Run, context: ElixirAttachContext): Promise<number> {
  const attach = await context.client.getRunAttach(run.id);
  if (attach.status === "unsupported") {
    console.error(`Attach unsupported for ${run.id}: ${attach.reason ?? "no attach target available"}`);
    const alternatives = Array.isArray(attach.alternatives) ? attach.alternatives : [];
    for (const alternative of alternatives) console.error(`  ${alternative}`);
    return 1;
  }

  const attachMap = attach.attach ?? {};
  const sessionId = typeof attach.session_id === "string"
    ? attach.session_id
    : typeof attachMap.session_id === "string"
      ? attachMap.session_id
      : null;
  if (sessionId) {
    console.log(`Attaching to ${run.seed_id} [${run.agent_type}] session=${sessionId}`);
    console.log(`  Status: ${run.status}`);
    if (run.worktree_path) console.log(`  Worktree: ${run.worktree_path}`);
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

      child.on("exit", (code) => resolve(code ?? 0));
    });
  }

  const streamUrl = typeof attachMap.stream_url === "string" ? attachMap.stream_url : null;
  if (streamUrl) {
    console.log(`Attach stream available for ${run.seed_id}: ${streamUrl}`);
    return 0;
  }

  console.log(`Attach request recorded for ${run.seed_id}. No resumable session id exposed.`);
  console.log(`Use 'foreman logs ${run.id}' for log output.`);
  return 0;
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
  const pid = getWorkerPid(run);
  if (!pid) {
    console.log("No pid found for this run.");
    return 0;
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

async function handleKillDaemon(
  run: Run,
  context: DaemonAttachContext,
  store: ForemanStore,
  fallbackRun: Run,
): Promise<number> {
  const pid = getWorkerPid(run);
  if (!pid) {
    console.log("No pid found for this run.");
    return 0;
  }

  try {
    await context.client.runs.updateStatus({ runId: run.id, status: "stuck" });
  } catch {
    return handleKill(fallbackRun, store);
  }

  try {
    process.kill(pid, "SIGTERM");
    console.log(`Sent SIGTERM to pid ${pid}`);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`Failed to kill pid ${pid}: ${msg}`);
    return 1;
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

function getWorkerPid(run: Run): number | null {
  return extractPid(run.session_key);
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
  .argument("[id]", "Run ID or task ID to attach to")
  .option("--list", "List all attachable sessions")
  .option("--follow", "Follow agent log file in real-time (tail -f)")
  .option("--stream", "Stream Agent Mail messages for the run in real-time")
  .option("--kill", "Kill the agent process for this run")
  .option("--worktree", "Open a shell in the agent's worktree instead of attaching")
  .action(async (id: string | undefined, opts: AttachOpts) => {
    const projectPath = await resolveRepoRootProjectPath({});
    const elixir = await resolveElixirAttachContext(projectPath);
    const daemon = elixir ? null : await resolveDaemonAttachContext(projectPath);
    let store: ForemanStore | null = null;

    if (opts.list) {
      try {
        if (elixir) {
          await listSessionsEnhancedElixir(elixir);
        } else if (daemon) {
          await listSessionsEnhancedDaemon(daemon);
        } else {
          store = ForemanStore.forProject(projectPath);
          listSessionsEnhanced(store, projectPath);
        }
      } catch (err) {
        if (foremanBackendMode() === "elixir") {
          const message = err instanceof Error ? err.message : String(err);
          console.error(`Elixir attach session list unavailable; refusing legacy local fallback. Set FOREMAN_BACKEND=node for legacy attach. Cause: ${message}`);
          process.exit(1);
        }
        store = store ?? ForemanStore.forProject(projectPath);
        listSessionsEnhanced(store, projectPath);
      }
      store?.close();
      return;
    }

    if (!id) {
      console.error("Usage: foreman attach <run-id|task-id>");
      console.error("       foreman attach --list");
      console.error("       foreman attach --follow <id>");
      console.error("       foreman attach --stream <id>");
      console.error("       foreman attach --kill <id>");
      process.exit(1);
    }

    if (elixir && opts.kill) {
      console.error("Error: attach --kill is not supported by the Elixir backend yet.");
      console.error("Use FOREMAN_BACKEND=node for legacy daemon kill control, or stop the process directly.");
      process.exit(1);
    }

    if (elixir) {
      try {
        const elixirRun = await resolveElixirRun(elixir, id);
        if (elixirRun) {
          if (opts.follow) {
            console.error("Error: attach --follow tails local worker files and is legacy-only in default Elixir mode.");
            console.error("Use attach --stream for Elixir inbox/event streaming, or set FOREMAN_BACKEND=node for legacy file follow.");
            process.exit(1);
          }
          const exitCode = opts.stream
            ? await handleStreamElixir(elixirRun, elixir, opts._signal, opts._pollIntervalMs)
            : opts.worktree
              ? await handleWorktree(elixirRun)
              : await handleDefaultAttachElixir(elixirRun, elixir);
          process.exit(exitCode);
        }
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        console.error(`Elixir attach lookup unavailable; refusing legacy daemon/local fallback. Set FOREMAN_BACKEND=node for legacy attach. Cause: ${message}`);
        process.exit(1);
      }
      console.error(`Run or task '${id}' not found in Elixir projections; refusing legacy daemon/local attach fallback. Set FOREMAN_BACKEND=node for legacy attach.`);
      process.exit(1);
    }

    if (daemon && !opts.kill) {
      try {
        const daemonRun = await resolveDaemonRun(daemon, id);
        if (daemonRun) {
          const exitCode = opts.stream
            ? await handleStreamDaemon(daemonRun, daemon, opts._signal, opts._pollIntervalMs)
            : opts.worktree
              ? await handleWorktree(daemonRun)
              : opts.follow
                ? await handleFollow(daemonRun, opts._signal)
                : await handleDefaultAttach(daemonRun);
          process.exit(exitCode);
        }
      } catch {
        // Fall back to the local store path when daemon lookup fails.
      }
    }

    store = store ?? ForemanStore.forProject(projectPath);
    const exitCode = await attachAction(id, opts, store, projectPath, opts.kill ? daemon : undefined);
    store.close();
    process.exit(exitCode);
  });
