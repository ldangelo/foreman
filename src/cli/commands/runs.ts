/**
 * `foreman runs` — Operator traceability dashboard for active Foreman runs.
 *
 * Lists active (pending/running) runs with task, phase, elapsed time,
 * last event/tool, cost/turns if known, and stuck/fatal indicators.
 *
 * Options:
 *   --project <name>     Registered project name (default: current directory)
 *   --project-path <path>  Absolute project path (advanced/script usage)
 *   --verbose            Show log path, report path, and cost/turns columns
 *   --json               Output runs as a JSON array
 *   --stuck              Show only runs that are likely stuck (>15 min inactive)
 *   --all                Include completed/failed runs in summary count
 */

import { Command } from "commander";
import chalk from "chalk";
import { ForemanStore } from "../../lib/store.js";
import type { Run, RunProgress } from "../../lib/store.js";
import { foremanBackendMode } from "../../lib/backend-mode.js";
import { ElixirServerClient, type ElixirRun } from "../../lib/elixir-server-client.js";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";
import { elapsed } from "../watch-ui.js";
import { getLastPiActivity } from "./status.js";
import {
  listRegisteredProjects,
  resolveRepoRootProjectPath,
  requireProjectOrAllInMultiMode,
} from "./project-task-support.js";

// ── Stuck detection ──────────────────────────────────────────────────────

/**
 * Minutes of inactivity before a running agent is flagged as stuck.
 * Mirrors PIPELINE_LIMITS.stuckDetectionMinutes from orchestrator config.
 */
const STUCK_THRESHOLD_MINUTES = 15;

/**
 * Returns true when a run appears stuck:
 * - Status is "pending" or "running"
 * - Elapsed time exceeds STUCK_THRESHOLD_MINUTES
 */
export function isStuck(run: Run, progress: RunProgress | null): boolean {
  if (run.status !== "pending" && run.status !== "running") return false;
  const since = progress?.lastActivity ?? run.started_at ?? run.created_at;
  const elapsedMs = Date.now() - new Date(since).getTime();
  return elapsedMs > STUCK_THRESHOLD_MINUTES * 60 * 1000;
}

export function filterStuckRuns(runs: Run[], progressByRunId: Map<string, RunProgress | null>): Run[] {
  return runs.filter((run) => isStuck(run, progressByRunId.get(run.id) ?? null));
}

// ── Run row type ─────────────────────────────────────────────────────────

export interface RunRow {
  id: string;
  task: string;          // seed_id / task ID
  status: string;
  phase: string | null;
  workerPid: string | null;
  elapsed: string;
  lastEvent: string | null;
  logPath: string | null;
  reportPath: string | null;
  cost: string | null;
  turns: number | null;
  indicators: string[];
  raw: Run | ElixirRun;
}

// ── Table formatting ──────────────────────────────────────────────────────

function pad(val: string, width: number): string {
  if (val.length > width) return val.slice(0, width - 1) + "…";
  return val.padEnd(width, " ");
}

function nullDash(val: string | null): string {
  return val ?? "—";
}

/**
 * Render an array of RunRow objects as a space-aligned ASCII table.
 * Columns adapt to data width with sensible minimums.
 */
export function renderRunsTable(rows: RunRow[], verbose = false): string {
  if (rows.length === 0) return "";

  // Column minimums (verbose includes extra columns)
  const MIN = {
    id: 8,
    task: 20,
    status: 10,
    phase: 12,
    elapsed: 8,
    lastEvent: 20,
    logPath: 36,
    reportPath: 36,
    cost: 10,
    turns: 6,
    indicators: 12,
  };

  const maxes = {
    id: Math.max(MIN.id, ...rows.map((r) => r.id.length)),
    task: Math.max(MIN.task, ...rows.map((r) => r.task.length)),
    status: Math.max(MIN.status, ...rows.map((r) => r.status.length)),
    phase: Math.max(MIN.phase, ...rows.map((r) => (r.phase ?? "—").length)),
    elapsed: MIN.elapsed,
    lastEvent: Math.max(MIN.lastEvent, ...rows.map((r) => (r.lastEvent ?? "—").length)),
    logPath: verbose ? Math.max(MIN.logPath, ...rows.map((r) => (r.logPath ?? "—").length)) : 0,
    reportPath: verbose ? Math.max(MIN.reportPath, ...rows.map((r) => (r.reportPath ?? "—").length)) : 0,
    cost: verbose ? Math.max(MIN.cost, ...rows.map((r) => (r.cost ?? "—").length)) : 0,
    turns: verbose ? MIN.turns : 0,
    indicators: Math.max(MIN.indicators, ...rows.map((r) => r.indicators.join(" ").length)),
  };

  const baseCols = [maxes.id, maxes.task, maxes.status, maxes.phase, maxes.elapsed, maxes.lastEvent];
  const verboseCols = verbose
    ? [maxes.logPath, maxes.reportPath, maxes.cost, maxes.turns]
    : [];
  const totalWidth =
    baseCols.reduce((a, b) => a + b, 0) +
    verboseCols.reduce((a, b) => a + b, 0) +
    maxes.indicators +
    (baseCols.length - 1 + verboseCols.length) + // separators
    1;

  const hr = "─".repeat(Math.min(totalWidth, 200));
  const sep = " │ ";

  const headerCols = ["RUN_ID", "TASK", "STATUS", "PHASE", "ELAPSED", "LAST_EVENT"];
  const verboseHeaders = verbose ? ["LOG_PATH", "REPORT_PATH", "COST", "TURNS"] : [];
  const headerLine = [...headerCols, ...verboseHeaders, "INDICATORS"]
    .map((h, i) => {
      const widths = [...baseCols, ...verboseCols, maxes.indicators];
      return pad(h, widths[i]!);
    })
    .join(sep);

  const formatRow = (r: RunRow): string => {
    const base = [
      pad(r.id.slice(0, maxes.id), maxes.id),
      pad(r.task, maxes.task),
      pad(r.status.toUpperCase(), maxes.status),
      pad(nullDash(r.phase), maxes.phase),
      pad(r.elapsed, maxes.elapsed),
      pad(nullDash(r.lastEvent), maxes.lastEvent),
    ];
    const verboseVals = verbose
      ? [
          pad(nullDash(r.logPath ?? null), maxes.logPath),
          pad(nullDash(r.reportPath ?? null), maxes.reportPath),
          pad(nullDash(r.cost), maxes.cost),
          pad(r.turns !== null ? String(r.turns) : "—", maxes.turns),
        ]
      : [];
    const statusColor = (s: string): string => {
      switch (s.toLowerCase()) {
        case "completed":   return chalk.green(s.toUpperCase());
        case "merged":      return chalk.green(s.toUpperCase());
        case "failed":      return chalk.red(s.toUpperCase());
        case "test-failed": return chalk.red(s.toUpperCase());
        case "conflict":    return chalk.magenta(s.toUpperCase());
        case "running":     return chalk.blue(s.toUpperCase());
        case "stuck":       return chalk.yellow(s.toUpperCase());
        case "pending":     return chalk.gray(s.toUpperCase());
        default:            return chalk.gray(s.toUpperCase());
      }
    };
    return [...base, ...verboseVals, pad(r.indicators.join(" "), maxes.indicators)]
      .map((cell, i) => (i === 2 ? statusColor(cell.trim()) : cell))
      .join(sep);
  };

  return [hr, headerLine, hr, ...rows.map(formatRow), hr].join("\n");
}

// ── JSON serialization ───────────────────────────────────────────────────

export interface RunJson {
  id: string;
  task: string;
  status: string;
  phase: string | null;
  workerPid: string | null;
  elapsed: string;
  elapsedMs: number;
  lastEvent: string | null;
  logPath: string | null;
  reportPath: string | null;
  cost: string | null;
  turns: number | null;
  indicators: string[];
  stuck: boolean;
  startedAt: string | null;
  createdAt: string;
}

/** Convert a RunRow to a JSON-serializable object. */
export function runToJson(row: RunRow): RunJson {
  const since = stringField(row.raw, "started_at") ?? stringField(row.raw, "created_at") ?? new Date().toISOString();
  return {
    id: row.id,
    task: row.task,
    status: row.status,
    phase: row.phase,
    workerPid: row.workerPid,
    elapsed: row.elapsed,
    elapsedMs: Date.now() - new Date(since).getTime(),
    lastEvent: row.lastEvent,
    logPath: row.logPath,
    reportPath: row.reportPath,
    cost: row.cost,
    turns: row.turns,
    indicators: row.indicators,
    stuck: row.indicators.includes("STUCK"),
    startedAt: stringField(row.raw, "started_at"),
    createdAt: stringField(row.raw, "created_at") ?? since,
  };
}

function stringField(source: object, key: string): string | null {
  const value = (source as Record<string, unknown>)[key];
  return typeof value === "string" && value.length > 0 ? value : null;
}

function numberField(source: object, key: string): number | null {
  const value = (source as Record<string, unknown>)[key];
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function isElixirActiveRun(run: ElixirRun): boolean {
  const status = stringField(run, "status");
  return status === "pending" || status === "running" || status === "in_progress";
}

function isElixirStuckRun(run: ElixirRun): boolean {
  if (run.stuck === true) return true;
  if (!isElixirActiveRun(run)) return false;
  const since = stringField(run, "updated_at") ?? stringField(run, "started_at") ?? stringField(run, "created_at");
  return since ? Date.now() - new Date(since).getTime() > STUCK_THRESHOLD_MINUTES * 60 * 1000 : false;
}

async function nodeRunToRow(run: Run, progress: RunProgress | null): Promise<RunRow> {
  const lastEvent = await getLastPiActivity(run.id);
  const since = run.started_at ?? run.created_at;
  const indicators: string[] = [];
  if (run.status === "failed") indicators.push("FATAL");
  if (isStuck(run, progress)) indicators.push("STUCK");
  if (run.status === "conflict") indicators.push("CONFLICT");
  if (run.status === "test-failed") indicators.push("TEST-FAIL");

  let costStr: string | null = null;
  let turns: number | null = null;
  if (progress) {
    if (progress.costUsd > 0) costStr = `$${progress.costUsd.toFixed(4)}`;
    if (progress.turns > 0) turns = progress.turns;
  }

  return {
    id: run.id,
    task: run.seed_id,
    status: run.status,
    phase: progress?.currentPhase ?? null,
    workerPid: null,
    elapsed: elapsed(since),
    lastEvent,
    logPath: null,
    reportPath: null,
    cost: costStr,
    turns,
    indicators,
    raw: run,
  };
}

function elixirRunToRow(run: ElixirRun): RunRow {
  const id = stringField(run, "run_id") ?? stringField(run, "id") ?? "unknown";
  const status = stringField(run, "status") ?? "unknown";
  const startedAt = stringField(run, "started_at") ?? stringField(run, "created_at") ?? new Date().toISOString();
  const workerPid = stringField(run, "worker_pid") ?? (numberField(run, "worker_pid")?.toString() ?? null);
  const cost = numberField(run, "cost") ?? numberField(run, "cost_usd");
  const turns = numberField(run, "turns");
  const indicators: string[] = [];
  if (run.fatal === true || status === "failed") indicators.push("FATAL");
  if (isElixirStuckRun(run)) indicators.push("STUCK");
  if (status === "conflict") indicators.push("CONFLICT");
  if (status === "test-failed") indicators.push("TEST-FAIL");

  return {
    id,
    task: stringField(run, "task_id") ?? "unknown",
    status,
    phase: stringField(run, "current_phase"),
    workerPid,
    elapsed: elapsed(startedAt),
    lastEvent: stringField(run, "last_lifecycle_event"),
    logPath: stringField(run, "log_path"),
    reportPath: stringField(run, "report_path") ?? stringField(run, "report_paths"),
    cost: cost && cost > 0 ? `$${cost.toFixed(4)}` : null,
    turns,
    indicators,
    raw: run,
  };
}

// ── Main command ─────────────────────────────────────────────────────────

export const runsCommand = new Command("runs")
  .description("Operator traceability dashboard: list active runs with phase, elapsed time, and indicators")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .option("--verbose", "Show log path, report path, and cost/turns columns")
  .option("--json", "Output runs as a JSON array")
  .option("--stuck", "Show only runs likely stuck (>15 min inactive)")
  .option("--all", "Include completed/failed runs in the summary count")
  .action(async (opts: {
    project?: string;
    projectPath?: string;
    verbose?: boolean;
    json?: boolean;
    stuck?: boolean;
    all?: boolean;
  }) => {
    await requireProjectOrAllInMultiMode(opts.project, opts.all ?? false);

    const useElixirRuns = foremanBackendMode() === "elixir";
    const skipProjectResolution = useElixirRuns && opts.all && !opts.project && !opts.projectPath;
    const projectPath = skipProjectResolution
      ? process.cwd()
      : await resolveRepoRootProjectPath({
          project: opts.project,
          projectPath: opts.projectPath,
        });

    let rows: RunRow[] = [];
    if (useElixirRuns) {
      const projects = await listRegisteredProjects();
      const registered = skipProjectResolution
        ? undefined
        : opts.project
          ? projects.find((project) => project.id === opts.project || project.name === opts.project || project.path === projectPath)
          : opts.projectPath
            ? projects.find((project) => project.path === projectPath)
            : projects.find((project) => project.path === projectPath);
      if (!registered && !(opts.all && !opts.project && !opts.projectPath)) {
        console.error(chalk.red(`Project at '${projectPath}' is not registered in Elixir. Run 'foreman project add' first.`));
        process.exit(1);
      }

      const manager = new ElixirServerManager();
      const status = await manager.ensureRunning();
      if (!status.running) {
        throw new Error("Elixir server is not running. Start it with 'foreman server start'.");
      }
      const client = new ElixirServerClient(status.url, process.env.FOREMAN_SERVER_AUTH_TOKEN);
      const elixirRuns = (await client.listRuns(registered?.id)).filter((run) => opts.all || isElixirActiveRun(run));
      const visibleRuns = opts.stuck ? elixirRuns.filter(isElixirStuckRun) : elixirRuns;
      rows = visibleRuns.map(elixirRunToRow);
    } else {
      const store = ForemanStore.forProject(projectPath);
      const project = store.getProjectByPath(projectPath);

      if (!project) {
        console.error(chalk.red(`Project at '${projectPath}' is not registered. Run 'foreman init' first.`));
        store.close();
        process.exit(1);
      }

      try {
        const allRuns = opts.all
          ? store.getRunsByStatuses(
              ["pending", "running", "completed", "failed", "stuck", "merged", "conflict", "test-failed", "pr-created"],
              project.id,
            )
          : store.getActiveRuns(project.id);

        const progressByRunId = new Map<string, RunProgress | null>();
        for (const run of allRuns) {
          progressByRunId.set(run.id, store.getRunProgress(run.id));
        }

        const activeRuns = opts.stuck ? filterStuckRuns(allRuns, progressByRunId) : allRuns;
        rows = await Promise.all(activeRuns.map((run) => nodeRunToRow(run, progressByRunId.get(run.id) ?? null)));
      } finally {
        store.close();
      }
    }

    if (opts.json) {
      console.log(JSON.stringify(rows.map(runToJson), null, 2));
      return;
    }

    const stuckCount = rows.filter((r) => r.indicators.includes("STUCK")).length;
    const failedCount = rows.filter((r) => r.indicators.includes("FATAL")).length;
    const activeCount = rows.filter((r) => r.status === "pending" || r.status === "running" || r.status === "in_progress").length;

    console.log(chalk.bold("Foreman Runs") + chalk.dim(`  (${rows.length} shown)`));
    if (stuckCount > 0) console.log(chalk.yellow(`  ⚠  ${stuckCount} stuck run(s) detected`));
    if (failedCount > 0) console.log(chalk.red(`  ✗  ${failedCount} failed run(s)`));
    if (!opts.stuck && opts.all) {
      console.log(
        `  Active: ${chalk.yellow(activeCount)}  |  ` +
        `Completed/Failed: ${chalk.cyan(rows.length - activeCount)}`,
      );
    }
    console.log("");

    if (rows.length === 0) {
      console.log(chalk.dim("  No active runs. Start the Elixir scheduler with `foreman server start`, then approve ready tasks. Use `FOREMAN_BACKEND=node foreman run` only for legacy dispatch."));
      return;
    }

    console.log(renderRunsTable(rows, opts.verbose ?? false));
    console.log("");
    if (!opts.verbose) {
      console.log(chalk.dim("  Use --verbose to show log path, report path, and cost/turns."));
    }
    if (!opts.stuck) {
      console.log(chalk.dim("  Use --stuck to filter to likely-stuck runs only."));
    }
  });
