import { spawn } from "node:child_process";
import { closeSync, existsSync, openSync, readSync, statSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import chalk from "chalk";
import { Command, Option } from "commander";
import type { TaskRow } from "../../lib/db/postgres-adapter.js";
import { ElixirServerClient } from "../../lib/elixir-server-client.js";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";
import { ForemanStore, type Run, type RunProgress } from "../../lib/store.js";
import { createTrpcClient } from "../../lib/trpc-client.js";
import { elapsed } from "../watch-ui.js";
import { listRegisteredProjects, resolveProjectPathFromOptions } from "./project-task-support.js";

interface LogsOpts {
  project?: string;
  projectPath?: string;
  run?: string;
  tail?: string;
  follow?: boolean;
  raw?: boolean;
  compact?: boolean;
  plain?: boolean;
  view?: "compact" | "plain" | "raw";
}

interface ResolvedRun {
  run: Run;
  progress: RunProgress | null;
  taskId?: string;
}

export function shouldRequireLocalRawLog(opts: Pick<LogsOpts, "compact" | "plain" | "raw" | "view" | "follow">): boolean {
  const eventBacked = opts.compact || opts.plain || opts.raw || opts.view === "compact" || opts.view === "plain" || opts.view === "raw";
  return !eventBacked || Boolean(opts.follow);
}

interface PhaseEvent {
  timestamp?: string;
  message: string;
}

interface RecentToolEvent {
  kind: "start" | "end";
  tool: string;
  detail?: string;
}

function logsDir(): string {
  return join(homedir(), ".foreman", "logs");
}

function logPath(runId: string, suffix: "log" | "err" | "out"): string {
  return join(logsDir(), `${runId}.${suffix}`);
}

function parseTailCount(value: string | undefined): number {
  const parsed = Number.parseInt(value ?? "80", 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 80;
}

export function tailLines(content: string, count: number): string[] {
  const lines = content.split("\n");
  return lines.slice(Math.max(0, lines.length - count));
}

export function tailFileLines(path: string, count: number, maxBytes = 4 * 1024 * 1024): string[] {
  const stat = statSync(path);
  if (stat.size === 0) return [];

  const bytesToRead = Math.min(stat.size, maxBytes);
  const start = stat.size - bytesToRead;
  const buffer = Buffer.allocUnsafe(bytesToRead);
  const fd = openSync(path, "r");
  try {
    const bytesRead = readSync(fd, buffer, 0, bytesToRead, start);
    const lines = buffer.subarray(0, bytesRead).toString("utf8").split("\n");
    if (start > 0) lines.shift(); // Drop likely partial first line from bounded tail read.
    return lines.slice(Math.max(0, lines.length - count));
  } finally {
    closeSync(fd);
  }
}

function tryJson(line: string): Record<string, unknown> | null {
  try {
    const parsed = JSON.parse(line) as Record<string, unknown>;
    return parsed && typeof parsed === "object" ? parsed : null;
  } catch {
    return null;
  }
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" ? value as Record<string, unknown> : null;
}

function short(value: unknown, max = 120): string | undefined {
  if (value === undefined || value === null) return undefined;
  const text = typeof value === "string" ? value : JSON.stringify(value);
  if (!text) return undefined;
  return text.length > max ? `${text.slice(0, max - 1)}…` : text;
}

export function extractPhaseEvents(errContent: string): PhaseEvent[] {
  const events: PhaseEvent[] = [];
  for (const line of errContent.split("\n")) {
    const obj = tryJson(line);
    const message = typeof obj?.message === "string" ? obj.message : line;
    if (!message) continue;
    if (/\[(PIPELINE|FIX|DEVELOPER|QA|REVIEWER|FINALIZE|CLI-REVIEW|PR-REVIEW)|retryOnly|FAIL|PASS|Completed|Starting|Skipping/i.test(message)) {
      events.push({
        timestamp: typeof obj?.timestamp === "string" ? obj.timestamp : undefined,
        message,
      });
    }
  }
  return events;
}

export function extractRecentToolEvents(logContent: string, limit: number): RecentToolEvent[] {
  const events: RecentToolEvent[] = [];
  for (const line of logContent.split("\n")) {
    const obj = tryJson(line);
    if (!obj) continue;
    if (obj.type === "tool_execution_start") {
      const args = asRecord(obj.args);
      events.push({
        kind: "start",
        tool: String(obj.toolName ?? "tool"),
        detail: short(args?.command ?? args?.path ?? args?.file_path ?? args?.pattern ?? args),
      });
    } else if (obj.type === "tool_execution_end") {
      events.push({
        kind: "end",
        tool: String(obj.toolName ?? "tool"),
      });
    }
  }
  return events.slice(Math.max(0, events.length - limit));
}

function renderRunHeader(resolved: ResolvedRun): void {
  const { run, progress, taskId } = resolved;
  console.log(chalk.bold(`\n  Logs: ${taskId ?? run.seed_id ?? run.id}`));
  console.log(`  Run ID:      ${run.id}`);
  console.log(`  Status:      ${run.status}`);
  if (progress?.currentPhase) console.log(`  Phase:       ${progress.currentPhase}`);
  if (run.started_at) console.log(`  Started:     ${new Date(run.started_at).toLocaleString()}`);
  if (run.completed_at) console.log(`  Completed:   ${new Date(run.completed_at).toLocaleString()}`);
  if (progress?.lastActivity) {
    console.log(`  Activity:    ${elapsed(progress.lastActivity)} (${new Date(progress.lastActivity).toLocaleString()})`);
  }
  if (progress) {
    const parts = [
      `${progress.turns ?? 0} turns`,
      `${progress.toolCalls ?? 0} tools`,
      progress.costUsd ? `$${progress.costUsd.toFixed(4)}` : null,
      progress.lastToolCall ? `last: ${progress.lastToolCall}` : null,
    ].filter(Boolean);
    console.log(`  Progress:    ${parts.join(" │ ")}`);
  }
  console.log(`  Raw log:     ${logPath(run.id, "log")}`);
  console.log(`  Error log:   ${logPath(run.id, "err")}`);
  console.log(`  Out log:     ${logPath(run.id, "out")}`);
}

function renderFileStats(runId: string): void {
  for (const suffix of ["log", "err", "out"] as const) {
    const path = logPath(runId, suffix);
    if (!existsSync(path)) continue;
    const stat = statSync(path);
    console.log(chalk.dim(`    ${suffix}: ${stat.size} bytes, updated ${elapsed(stat.mtime.toISOString())}`));
  }
}

type CompactLogEntry = {
  timestamp?: string;
  stream?: string;
  type?: string;
  message?: string;
  body?: string;
};

function compactEntries(logs: unknown): CompactLogEntry[] {
  if (Array.isArray(logs)) return logs as CompactLogEntry[];
  const record = asRecord(logs);
  if (Array.isArray(record?.entries)) return record.entries as CompactLogEntry[];
  return [];
}

export function isMessageUpdateEntry(entry: CompactLogEntry): boolean {
  return entry.type === "message_update" || entry.stream === "message_update";
}

export async function renderCompactView(runId: string, tailCount: number, view: "compact" | "plain" | "raw" = "compact"): Promise<void> {
  try {
    const manager = new ElixirServerManager();
    const status = await manager.ensureRunning();
    const serverView = view === "plain" ? "compact" : view;
    const logs = await new ElixirServerClient(status.url, manager.authToken).getRunLogs(runId, serverView);
    const entries = compactEntries(logs).filter((entry) => view === "raw" || !isMessageUpdateEntry(entry)).slice(-tailCount);
    if (entries.length === 0) {
      console.log(chalk.dim(view === "raw" ? "(no raw log entries)" : "(no compact log entries)"));
      return;
    }
    for (const entry of entries) {
      if (view === "raw") {
        console.log(typeof entry === "string" ? entry : JSON.stringify(entry));
        continue;
      }
      const timestamp = entry.timestamp ? `${chalk.dim(new Date(entry.timestamp).toLocaleTimeString())} ` : "";
      const stream = entry.stream ?? entry.type ?? "event";
      const message = entry.message ?? entry.body ?? JSON.stringify(entry);
      console.log(`${timestamp}${chalk.cyan(`[${stream}]`)} ${message}`);
    }
  } catch {
    console.log(chalk.dim(`(${view} view unavailable — Elixir backend may not be running)`));
  }
}

function renderSummary(runId: string, tailCount: number): void {
  const errPath = logPath(runId, "err");
  const jsonLogPath = logPath(runId, "log");

  console.log(chalk.bold("\n  Log files:"));
  renderFileStats(runId);

  if (existsSync(errPath)) {
    const phases = extractPhaseEvents(tailFileLines(errPath, 5000).join("\n"));
    console.log(chalk.bold("\n  Phase/events:"));
    if (phases.length === 0) {
      console.log(chalk.dim("    (none found)"));
    } else {
      for (const event of phases.slice(-20)) {
        const prefix = event.timestamp ? chalk.dim(`[${new Date(event.timestamp).toLocaleTimeString()}] `) : "";
        console.log(`    ${prefix}${event.message}`);
      }
    }
  }

  if (existsSync(jsonLogPath)) {
    const content = tailFileLines(jsonLogPath, 5000).join("\n");
    const tools = extractRecentToolEvents(content, 20);
    console.log(chalk.bold("\n  Recent tool activity:"));
    if (tools.length === 0) {
      console.log(chalk.dim("    (none found)"));
    } else {
      for (const event of tools) {
        const mark = event.kind === "start" ? chalk.yellow("→") : chalk.green("✓");
        console.log(`    ${mark} ${event.tool}${event.detail ? chalk.dim(` ${event.detail}`) : ""}`);
      }
    }

    console.log(chalk.dim(`\n  Use --raw --tail ${tailCount} to print raw JSON lines.`));
  } else {
    console.log(chalk.dim("\n  Raw log not found."));
  }
}

function normalizeDaemonRun(row: Run & { bead_id?: string; finished_at?: string | null; progress?: RunProgress | string | null }): Run {
  return {
    ...row,
    seed_id: row.seed_id ?? row.bead_id ?? row.id,
    completed_at: row.completed_at ?? row.finished_at ?? null,
  };
}

function progressFromRun(row: { progress?: RunProgress | string | null }): RunProgress | null {
  if (!row.progress) return null;
  if (typeof row.progress === "string") {
    try {
      return JSON.parse(row.progress) as RunProgress;
    } catch {
      return null;
    }
  }
  return row.progress;
}

function adaptElixirRun(row: Record<string, unknown>): Run {
  return {
    id: String(row.run_id ?? row.id),
    project_id: String(row.project_id ?? ""),
    seed_id: String(row.task_id ?? row.seed_id ?? row.bead_id ?? row.run_id ?? row.id),
    agent_type: typeof row.agent_type === "string" ? row.agent_type : "elixir",
    session_key: typeof row.session_key === "string" ? row.session_key : null,
    worktree_path: typeof row.worktree_path === "string" ? row.worktree_path : null,
    status: (typeof row.status === "string" ? row.status : "pending") as Run["status"],
    started_at: typeof row.started_at === "string" ? row.started_at : null,
    completed_at: typeof row.completed_at === "string" ? row.completed_at : typeof row.finished_at === "string" ? row.finished_at : null,
    created_at: typeof row.created_at === "string" ? row.created_at : new Date(0).toISOString(),
    progress: typeof row.progress === "string" ? row.progress : row.progress ? JSON.stringify(row.progress) : null,
    base_branch: typeof row.base_branch === "string" ? row.base_branch : null,
    merge_strategy: (typeof row.merge_strategy === "string" ? row.merge_strategy : null) as Run["merge_strategy"],
  };
}

async function resolveElixirRun(id: string | undefined, opts: LogsOpts): Promise<ResolvedRun | null> {
  const manager = new ElixirServerManager();
  const status = await manager.ensureRunning();
  const client = new ElixirServerClient(status.url, manager.authToken);
  const projects = await listRegisteredProjects();
  const projectPath = await resolveProjectPathFromOptions(opts);
  const project = projects.find((entry) => entry.path === projectPath || entry.name === opts.project || entry.id === opts.project);
  const projectId = project?.id;
  const runId = opts.run ?? id;

  if (runId) {
    const direct = await client.getRun(runId);
    if (direct) {
      const run = adaptElixirRun(direct);
      return { run, progress: progressFromRun(run), taskId: run.seed_id };
    }
  }

  const runs = (await client.listRuns(projectId)).map(adaptElixirRun);
  if (!id) {
    const latest = runs[0];
    return latest ? { run: latest, progress: progressFromRun(latest), taskId: latest.seed_id } : null;
  }

  const match = runs.find((run) => run.id === id || run.id.startsWith(id) || run.seed_id === id || run.seed_id.startsWith(id));
  return match ? { run: match, progress: progressFromRun(match), taskId: match.seed_id } : null;
}

async function resolveDaemonRun(id: string | undefined, opts: LogsOpts): Promise<ResolvedRun | null> {
  const projectPath = await resolveProjectPathFromOptions(opts);
  const projects = await listRegisteredProjects();
  const project = projects.find((entry) => entry.path === projectPath || entry.name === opts.project || entry.id === opts.project);
  if (!project) return null;

  const client = createTrpcClient();
  const runId = opts.run ?? id;
  if (runId && /^[0-9a-f-]{8,}$/i.test(runId)) {
    try {
      const directRow = await client.runs.get({ runId }) as (Run & { bead_id?: string; finished_at?: string | null; progress?: RunProgress | string | null }) | null;
      if (directRow) {
        const run = normalizeDaemonRun(directRow);
        const progress = await client.runs.getProgress({ runId: run.id }) as RunProgress | null;
        return { run, progress: progress ?? progressFromRun(directRow), taskId: run.seed_id };
      }
    } catch {
      // Treat positional non-run IDs as task IDs below.
    }
  }

  if (!id) return null;

  const tasks = await client.tasks.list({ projectId: project.id }) as TaskRow[];
  const matches = tasks.filter((task) => task.id === id || task.id.startsWith(id));
  if (matches.length === 1 && matches[0]?.run_id) {
    const runRow = await client.runs.get({ runId: matches[0].run_id }) as (Run & { bead_id?: string; finished_at?: string | null; progress?: RunProgress | string | null }) | null;
    if (!runRow) return null;
    const run = normalizeDaemonRun(runRow);
    const progress = await client.runs.getProgress({ runId: run.id }) as RunProgress | null;
    return { run, progress: progress ?? progressFromRun(runRow), taskId: matches[0].id };
  }

  const runRows = await client.runs.list({ projectId: project.id, limit: 100 }) as Array<Run & { bead_id?: string; finished_at?: string | null; progress?: RunProgress | string | null }>;
  const runs = runRows.map(normalizeDaemonRun);
  const match = runs.find((run) => run.id === id || run.id.startsWith(id) || run.seed_id === id || run.seed_id.startsWith(id));
  if (!match) return null;
  const progress = await client.runs.getProgress({ runId: match.id }) as RunProgress | null;
  return { run: match, progress: progress ?? progressFromRun(runRows.find((row) => row.id === match.id) ?? {}), taskId: match.seed_id };
}

async function resolveLocalRun(id: string | undefined, opts: LogsOpts): Promise<ResolvedRun | null> {
  const projectPath = await resolveProjectPathFromOptions(opts);
  const store = ForemanStore.forProject(projectPath);
  try {
    const project = store.getProjectByPath(projectPath);
    const runId = opts.run ?? id;
    if (runId) {
      const direct = store.getRun(runId);
      if (direct) return { run: direct, progress: store.getRunProgress(direct.id), taskId: direct.seed_id };
    }
    if (!id || !project) return null;
    const runs = store.getRunsForSeed(id, project.id);
    if (runs.length > 0 && runs[0]) {
      return { run: runs[0], progress: store.getRunProgress(runs[0].id), taskId: id };
    }
    return null;
  } finally {
    store.close();
  }
}

async function resolveRun(id: string | undefined, opts: LogsOpts): Promise<ResolvedRun | null> {
  try {
    const elixir = await resolveElixirRun(id, opts);
    if (elixir) return elixir;
  } catch {
    // Fall back to daemon/local stores when the Elixir server is unavailable.
  }
  try {
    const daemon = await resolveDaemonRun(id, opts);
    if (daemon) return daemon;
  } catch {
    // Fall back to local store when daemon is unavailable.
  }
  return resolveLocalRun(id, opts);
}

function followFile(path: string): Promise<number> {
  return new Promise((resolve) => {
    const child = spawn("tail", ["-f", path], { stdio: "inherit" });
    child.on("exit", (code) => resolve(code ?? 0));
    child.on("error", () => resolve(1));
  });
}

export const logsCommand = new Command("logs")
  .description("Show run logs and debugging summary")
  .argument("[id]", "Task ID, task prefix, or run ID")
  .option("--run <runId>", "Run ID (overrides positional ID)")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .option("--tail <lines>", "Raw log lines to show", "80")
  .option("--follow", "Follow the raw JSON log after printing the summary")
  .option("--raw", "Print only the raw JSON log tail")
  .option("--compact", "Compact plain view — strips message_update noise, fetches from Elixir backend")
  .option("--plain", "Alias for --compact")
  .addOption(new Option("--view <view>", "Log view for event-backed logs").choices(["compact", "plain", "raw"]))
  .action(async (id: string | undefined, opts: LogsOpts) => {
    const tailCount = parseTailCount(opts.tail);
    const resolved = await resolveRun(id, opts);
    if (!resolved) {
      console.error(chalk.red(`Error: No run found for '${opts.run ?? id ?? "(none)"}'.`));
      process.exit(1);
    }

    const rawPath = logPath(resolved.run.id, "log");
    if (shouldRequireLocalRawLog(opts) && !existsSync(rawPath)) {
      console.error(chalk.red(`Error: Raw log not found: ${rawPath}`));
      process.exit(1);
    }

    const view = opts.view;
    const compact = opts.compact || opts.plain || view === "compact" || view === "plain";
    const raw = opts.raw || view === "raw";

    if (compact) {
      await renderCompactView(resolved.run.id, tailCount, view === "plain" || opts.plain ? "plain" : "compact");
    } else if (raw) {
      if (existsSync(rawPath)) {
        for (const line of tailFileLines(rawPath, tailCount)) {
          if (line.trim()) console.log(line);
        }
      } else {
        await renderCompactView(resolved.run.id, tailCount, "raw");
      }
    } else {
      renderRunHeader(resolved);
      renderSummary(resolved.run.id, tailCount);
      console.log();
    }

    if (opts.follow) {
      process.exitCode = await followFile(rawPath);
    }
  });
