/**
 * `foreman task` CLI commands — manage daemon-backed tasks in the Foreman task store.
 *
 * Sub-commands:
 *   foreman task create --title <text> [--description <text>] [--type <type>]
 *                        [--priority <level>]
 *   foreman task create --from-text "<description>" [--type <type>] [--priority <level>]
 *                        [--parent <id>] [--dry-run] [--no-llm] [--model <model>]
 *   foreman task list [--status <status>] [--all]
 *   foreman task show <id>
 *   foreman task update <id> [--title <text>] [--description <text>]
 *                           [--priority <level>] [--status <status>] [--force]
 *   foreman task approve <id>
 *   foreman task close <id>
 *   foreman task dep add <from-id> <to-id> [--type blocks|parent-child]
 *   foreman task dep list <id>
 *   foreman task dep remove <from-id> <to-id> [--type blocks|parent-child] (removed after Elixir cutover)
 *
 * @module src/cli/commands/task
 */

import { Command } from "commander";
import { randomBytes, randomUUID } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import chalk from "chalk";
import type { TaskDependencyRow as DependencyRow, TaskNoteRow, TaskRow } from "../../lib/db/postgres-adapter.js";
import { resolveProjectPathFromOptions } from "./project-task-support.js";
import type { RegisteredProjectSummary } from "./project-task-support.js";
import { findRegisteredProjectByPath } from "./project-context.js";
import { foremanBackendMode } from "../../lib/backend-mode.js";
import { ElixirServerClient, type ElixirRun, type ElixirTask } from "../../lib/elixir-server-client.js";
import { ElixirServerManager } from "../../lib/elixir-server-manager.js";
import type { PrState } from "../../lib/pr-state.js";
import { ForemanStore } from "../../lib/store.js";
import type { RunProgress } from "../../lib/store.js";
import { elapsed } from "../watch-ui.js";

// ── Run Activity Helpers ──────────────────────────────────────────────────────

/** Threshold in ms after which a running agent is considered potentially stuck. */
const STUCK_THRESHOLD_MS = 15 * 60 * 1000; // 15 minutes

interface RunActivityInfo {
  runId: string | null;
  status: string;
  currentPhase: string | null;
  lastActivity: string | null;
  lastActivityElapsed: string | null;
  isStuck: boolean;
  isStale: boolean;  // no recent tool calls despite running
  toolCalls: number;
  costUsd: number;
  turns: number;
  startedAt: string | null;
  completedAt: string | null;
}

/**
 * Fetch live run activity information for a task.
 * 
 * Uses Elixir run projections for registered projects and never opens the removed Node daemon socket.
 */
async function fetchRunActivity(
  projectPath: string,
  runId: string | null,
  projectId?: string,
): Promise<RunActivityInfo | null> {
  if (!runId) return null;

  if (projectId && foremanBackendMode() === "elixir") {
    const client = await createElixirTaskCommandClient();
    const runs = await client.listRuns({ projectId });
    const run = runs.find((candidate) => (candidate.run_id ?? candidate.id) === runId);
    return run ? elixirRunToActivity(run) : null;
  }


  // Fallback: use Postgres store (for unregistered projects or daemon unavailability)
  const store = ForemanStore.forProject(projectPath);
  try {
    const run = store.getRun(runId);
    if (!run) return null;

    const progress = store.getRunProgress(runId);
    const now = Date.now();

    // Detect stuck: running but no activity for > STUCK_THRESHOLD_MS
    const lastActivityMs = progress?.lastActivity
      ? new Date(progress.lastActivity).getTime()
      : null;
    const isStuck = run.status === "running" &&
      lastActivityMs !== null &&
      (now - lastActivityMs) > STUCK_THRESHOLD_MS;

    // Detect stale: has tool calls but no recent activity
    const isStale = run.status === "running" &&
      (progress?.toolCalls ?? 0) > 0 &&
      lastActivityMs !== null &&
      (now - lastActivityMs) > STUCK_THRESHOLD_MS / 2; // half threshold

    return {
      runId: run.id,
      status: run.status,
      currentPhase: progress?.currentPhase ?? null,
      lastActivity: progress?.lastActivity ?? null,
      lastActivityElapsed: progress?.lastActivity
        ? elapsed(progress.lastActivity)
        : null,
      isStuck,
      isStale,
      toolCalls: progress?.toolCalls ?? 0,
      costUsd: progress?.costUsd ?? 0,
      turns: progress?.turns ?? 0,
      startedAt: run.started_at,
      completedAt: run.completed_at,
    };
  } finally {
    store.close();
  }
}

/**
 * Render a human-readable status line for a run's activity state.
 */
export function renderRunStatusLine(activity: RunActivityInfo): string {
  const parts: string[] = [];

  // Status with color coding
  if (activity.isStuck) {
    parts.push(chalk.red("⚠ STUCK"));
  } else if (activity.status === "running") {
    parts.push(chalk.green("● RUNNING"));
  } else if (activity.status === "failed" || activity.status === "test-failed") {
    parts.push(chalk.red("✗ FAILED"));
  } else if (activity.status === "completed") {
    parts.push(chalk.cyan("✓ COMPLETED"));
  } else if (activity.status === "merged") {
    parts.push(chalk.green("⊕ MERGED"));
  } else if (activity.status === "stuck") {
    parts.push(chalk.yellow("⚠ STUCK"));
  } else if (activity.status === "conflict") {
    parts.push(chalk.yellow("⊘ CONFLICT"));
  } else {
    parts.push(chalk.dim(activity.status.toUpperCase()));
  }

  // Current phase
  if (activity.currentPhase) {
    const phaseColors: Record<string, (s: string) => string> = {
      explorer:  chalk.cyan,
      developer: chalk.green,
      qa:        chalk.yellow,
      reviewer:  chalk.magenta,
      finalize:  chalk.blue,
    };
    const colorFn = phaseColors[activity.currentPhase] ?? chalk.white;
    parts.push(chalk.dim("│") + " " + colorFn(activity.currentPhase));
  }

  // Last activity time
  if (activity.lastActivityElapsed) {
    parts.push(chalk.dim("│") + " " + chalk.dim("last activity") + " " + chalk.white(activity.lastActivityElapsed));
  }

  // Tool call count
  if (activity.toolCalls > 0) {
    parts.push(chalk.dim("│") + " " + chalk.dim(`${activity.toolCalls} tools`));
  }

  // Cost
  if (activity.costUsd > 0) {
    parts.push(chalk.dim("│") + " $" + activity.costUsd.toFixed(4));
  }

  return parts.join(" ");
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/** Column widths for the task table. */
const COL_ID = 16;
const COL_TITLE = 40;
const COL_TYPE = 10;
const COL_PRI = 14;
const COL_STATUS = 14;
const COL_GAP = "  ";
const COMPACT_TASK_ID_SUFFIX_HEX_LENGTH = 5;

const TASK_STATUS_ORDER: Record<string, number> = {
  backlog: 0,
  blocked: 0,
  ready: 1,
  "in-progress": 2,
  review: 2,
  explorer: 3,
  developer: 3,
  qa: 3,
  reviewer: 3,
  finalize: 4,
  merged: 5,
  closed: 5,
  conflict: -1,
  failed: -1,
  stuck: -1,
};

const ALL_TASK_STATUSES = Object.keys(TASK_STATUS_ORDER);
const VALID_TASK_TYPES = ["task", "bug", "feature", "epic", "chore", "docs", "question"];

interface TaskProjectRegistration {
  projectId: string;
  projectName: string;
  projectPath: string;
}

interface TaskProjectContext extends TaskProjectRegistration {
  client: any;
}

export function normalizeTaskIdPrefix(raw: string | null | undefined): string {
  const normalized = (raw ?? "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return normalized.length > 0 ? normalized : "task";
}

export function allocateTaskId(projectKey: string, existingIds: Set<string>): string {
  const prefix = normalizeTaskIdPrefix(projectKey);
  for (let attempt = 0; attempt < 64; attempt += 1) {
    const candidate = `${prefix}-${randomBytes(3).toString("hex").slice(0, COMPACT_TASK_ID_SUFFIX_HEX_LENGTH)}`;
    if (!existingIds.has(candidate)) {
      existingIds.add(candidate);
      return candidate;
    }
  }
  throw new Error(`Unable to allocate a unique task ID for prefix '${prefix}'.`);
}

function parsePriority(input: string): number {
  const normalized = input.trim().toLowerCase();
  if (/^[0-4]$/.test(normalized)) return Number(normalized);
  switch (normalized) {
    case "critical":
    case "p0":
      return 0;
    case "high":
    case "p1":
      return 1;
    case "medium":
    case "p2":
      return 2;
    case "low":
    case "p3":
      return 3;
    case "backlog":
    case "p4":
      return 4;
    default:
      throw new RangeError(`Invalid priority '${input}'.`);
  }
}

export function priorityLabel(priority: number): string {
  switch (priority) {
    case 0:
      return "critical";
    case 1:
      return "high";
    case 2:
      return "medium";
    case 3:
      return "low";
    case 4:
      return "backlog";
    default:
      return String(priority);
  }
}

export function formatTaskIdDisplay(taskId: string): string {
  return taskId.length <= 16 ? taskId : `${taskId.slice(0, 8)}…`;
}

async function resolveTaskProjectRegistration(
  opts: { project?: string; projectPath?: string },
): Promise<TaskProjectRegistration> {
  const projectPath = resolve(await resolveProjectPathFromOptions(opts));
  const record = await findRegisteredProjectByPath(projectPath, {
    normalizePaths: true,
    initPool: false,
  });
  if (!record) {
    throw new Error(
      `Project at '${projectPath}' is not registered with the daemon. Run 'foreman project list' to see registered projects.`,
    );
  }

  return {
    projectId: record.id,
    projectName: record.name,
    projectPath,
  };
}

async function resolveTaskProjectContext(
  _opts: { project?: string; projectPath?: string },
): Promise<TaskProjectContext> {
  throw new Error("The legacy Node task backend was removed after the Elixir backend cutover. Use an Elixir-backed task command.");
}

async function createElixirTaskCommandClient(): Promise<ElixirServerClient> {
  const manager = new ElixirServerManager();
  const status = await manager.ensureRunning();
  return new ElixirServerClient(status.url, process.env.FOREMAN_SERVER_AUTH_TOKEN);
}

function elixirTaskToTaskRow(task: ElixirTask): TaskRow {
  const id = task.task_id ?? task.id ?? "";
  return {
    id,
    title: task.title ?? id,
    description: task.description ?? null,
    type: task.task_type ?? task.type ?? "task",
    priority: typeof task.priority === "number" ? task.priority : 2,
    status: task.status ?? "backlog",
    created_at: task.created_at ?? new Date(0).toISOString(),
    updated_at: task.updated_at ?? task.created_at ?? new Date(0).toISOString(),
    approved_at: task.approved_at ?? null,
    closed_at: task.closed_at ?? null,
    external_id: task.external_id ?? null,
    run_id: typeof task.run_id === "string" ? task.run_id : null,
    dependencies: Array.isArray(task.dependencies) ? task.dependencies : [],
  } as unknown as TaskRow;
}

async function listAllTasks(client: any, projectId: string): Promise<TaskRow[]> {
  return await client.tasks.list({ projectId, limit: 1000 }) as TaskRow[];
}

async function listAllElixirTasks(client: ElixirServerClient, projectId: string): Promise<TaskRow[]> {
  const tasks = await client.listTasks();
  return tasks
    .filter((task) => (task.project_id ?? projectId) === projectId)
    .map(elixirTaskToTaskRow);
}

async function getElixirTaskRow(client: ElixirServerClient, taskId: string): Promise<TaskRow | null> {
  const task = await client.getTask(taskId);
  return task ? elixirTaskToTaskRow(task) : null;
}

function elixirRunToActivity(run: ElixirRun): RunActivityInfo {
  const runId = String(run.run_id ?? run.id ?? "");
  const status = String(run.status ?? "unknown");
  const currentPhase = typeof run.current_phase === "string" ? run.current_phase : null;
  const lastActivity = typeof run.updated_at === "string" ? run.updated_at : null;
  const startedAt = typeof run.started_at === "string" ? run.started_at : null;
  const completedAt = typeof run.completed_at === "string" ? run.completed_at : null;
  const now = Date.now();
  const lastActivityMs = lastActivity ? new Date(lastActivity).getTime() : null;
  const isStuck = status === "in_progress" && lastActivityMs !== null && (now - lastActivityMs) > STUCK_THRESHOLD_MS;

  return {
    runId,
    status,
    currentPhase,
    lastActivity,
    lastActivityElapsed: lastActivity ? elapsed(lastActivity) : null,
    isStuck,
    isStale: false,
    toolCalls: 0,
    costUsd: 0,
    turns: 0,
    startedAt,
    completedAt,
  };
}

async function sendElixirTaskCommand(
  client: ElixirServerClient,
  commandType: string,
  payload: Record<string, unknown>,
): Promise<void> {
  const commandId = `task-${commandType}-${randomUUID()}`;
  const response = await client.sendCommand({
    command_id: commandId,
    command_type: commandType,
    payload,
    metadata: { correlation_id: commandId, source: "foreman-task" },
  });
  if (!response.ok) {
    throw new Error(response.error.message);
  }
}

export function resolveTaskId(rows: TaskRow[], taskIdOrPrefix: string): string {
  const exact = rows.find((row) => row.id === taskIdOrPrefix);
  if (exact) {
    return exact.id;
  }
  const matches = rows.filter((row) => row.id.startsWith(taskIdOrPrefix));
  if (matches.length === 0) {
    throw new Error(`Task '${taskIdOrPrefix}' not found.`);
  }
  if (matches.length > 1) {
    throw new Error(`Ambiguous task ID prefix '${taskIdOrPrefix}'.`);
  }
  return matches[0].id;
}

export function isBackwardStatusTransition(fromStatus: string, toStatus: string): boolean {
  const fromOrder = TASK_STATUS_ORDER[fromStatus] ?? 0;
  const toOrder = TASK_STATUS_ORDER[toStatus] ?? 0;
  return toOrder >= 0 && fromOrder > toOrder;
}

function pad(str: string, width: number): string {
  return str.length >= width ? str.slice(0, width - 1) + "…" : str.padEnd(width);
}

function renderColumn(
  value: string,
  width: number,
  style: (text: string) => string = (text) => text,
): string {
  return style(pad(value, width));
}

export function colorPriority(text: string, priority: number): string {
  switch (priority) {
    case 0:
      return chalk.red(text);
    case 1:
      return chalk.yellow(text);
    case 2:
      return chalk.cyan(text);
    case 3:
      return chalk.dim(text);
    default:
      return chalk.dim(text);
  }
}

export function statusChalk(status: string): string {
  switch (status) {
    case "ready":
      return chalk.green(status);
    case "in-progress":
    case "explorer":
    case "developer":
    case "qa":
    case "reviewer":
    case "finalize":
      return chalk.cyan(status);
    case "merged":
    case "closed":
      return chalk.dim(status);
    case "blocked":
    case "conflict":
      return chalk.yellow(status);
    case "failed":
    case "stuck":
      return chalk.red(status);
    case "backlog":
    default:
      return chalk.dim(status);
  }
}

/**
 * Render a PR state badge for display in task list.
 */
export function renderPrBadge(prState: PrState | undefined): string {
  if (!prState) return chalk.dim("—");
  switch (prState.status) {
    case "none":
      return chalk.dim("no PR");
    case "open":
      return chalk.green(`#${prState.number}`);
    case "merged":
      if (prState.isStale) {
        return chalk.yellow(`#${prState.number} (stale)`);
      }
      return chalk.cyan(`#${prState.number}`);
    case "closed":
      return chalk.dim(`#${prState.number} (closed)`);
    case "error":
      return chalk.red("?");
    default:
      return chalk.dim("—");
  }
}

function printTaskTable(rows: TaskRow[], prStates?: Map<string, PrState>): void {
  if (rows.length === 0) {
    console.log(chalk.dim("No tasks found."));
    return;
  }

  const idWidth = Math.max(COL_ID, ...rows.map((row) => row.id.length));
  const showPr = prStates !== undefined;

  // Header
  const prHeader = showPr ? COL_GAP + chalk.bold(pad("PR", 12)) : "";
  console.log(
    chalk.bold(pad("ID", idWidth)) +
      COL_GAP +
      chalk.bold(pad("TITLE", COL_TITLE)) +
      COL_GAP +
      chalk.bold(pad("TYPE", COL_TYPE)) +
      COL_GAP +
      chalk.bold(pad("PRIORITY", COL_PRI)) +
      COL_GAP +
      chalk.bold("STATUS") +
      prHeader,
  );

  const prColWidth = 12;
  const separatorLen = idWidth + COL_TITLE + COL_TYPE + COL_PRI + COL_STATUS + (COL_GAP.length * 4) + (showPr ? prColWidth + COL_GAP.length : 0);
  console.log("─".repeat(separatorLen));

  for (const t of rows) {
    const prState = prStates?.get(t.id);
    const prBadge = renderPrBadge(prState);
    const prCell = showPr ? COL_GAP + pad(prBadge, prColWidth) : "";
    console.log(
      chalk.dim(t.id.padEnd(idWidth)) +
        COL_GAP +
        renderColumn(t.title, COL_TITLE) +
        COL_GAP +
        renderColumn(t.type, COL_TYPE, chalk.dim) +
        COL_GAP +
        renderColumn(priorityLabel(t.priority), COL_PRI, (text) => colorPriority(text, t.priority)) +
        COL_GAP +
        renderColumn(t.status, COL_STATUS, statusChalk) +
        prCell,
    );
  }
}

/**
 * Render a run status badge for the task table.
 */
export function renderRunStatusBadge(activity: RunActivityInfo | null): string {
  if (!activity) return chalk.dim("—");

  if (activity.isStuck) {
    return chalk.red("⚠ stuck");
  }
  if (activity.isStale) {
    return chalk.yellow("⚡ stale");
  }
  if (activity.status === "running" && activity.currentPhase) {
    const phaseColors: Record<string, (s: string) => string> = {
      explorer:  (s: string) => chalk.cyan(s),
      developer: (s: string) => chalk.green(s),
      qa:        (s: string) => chalk.yellow(s),
      reviewer:  (s: string) => chalk.magenta(s),
      finalize:  (s: string) => chalk.blue(s),
    };
    const colorFn = phaseColors[activity.currentPhase] ?? ((s: string) => s);
    return colorFn(activity.currentPhase);
  }
  switch (activity.status) {
    case "running":
      return chalk.green("● run");
    case "completed":
      return chalk.cyan("✓ done");
    case "merged":
      return chalk.green("⊕ merged");
    case "failed":
    case "test-failed":
      return chalk.red("✗ fail");
    case "stuck":
      return chalk.red("⚠ stuck");
    case "conflict":
      return chalk.yellow("⊘ conflict");
    default:
      return chalk.dim(activity.status);
  }
}

/**
 * Render task table with an additional RUN STATUS column.
 * Used for --show-run and --stuck views to display live run activity.
 */
function printTaskTableWithRunStatus(
  rows: TaskRow[],
  runActivityMap: Map<string, RunActivityInfo | null>,
  prStates?: Map<string, PrState>,
): void {
  if (rows.length === 0) {
    console.log(chalk.dim("No tasks found."));
    return;
  }

  const idWidth = Math.max(COL_ID, ...rows.map((row) => row.id.length));
  const showPr = prStates !== undefined;
  const runColWidth = 10;

  // Header
  const prHeader = showPr ? COL_GAP + chalk.bold(pad("PR", 12)) : "";
  console.log(
    chalk.bold(pad("ID", idWidth)) +
      COL_GAP +
      chalk.bold(pad("TITLE", COL_TITLE)) +
      COL_GAP +
      chalk.bold(pad("TYPE", COL_TYPE)) +
      COL_GAP +
      chalk.bold(pad("PRIORITY", COL_PRI)) +
      COL_GAP +
      chalk.bold("STATUS") +
      COL_GAP +
      chalk.bold(pad("RUN", runColWidth)) +
      prHeader,
  );

  const prColWidth = 12;
  const separatorLen = idWidth + COL_TITLE + COL_TYPE + COL_PRI + COL_STATUS + runColWidth + (COL_GAP.length * 5) + (showPr ? prColWidth + COL_GAP.length : 0);
  console.log("─".repeat(separatorLen));

  for (const t of rows) {
    const activity = runActivityMap.get(t.id) ?? null;
    const prState = prStates?.get(t.id);
    const prBadge = renderPrBadge(prState);
    const prCell = showPr ? COL_GAP + pad(prBadge, prColWidth) : "";
    const runBadge = renderRunStatusBadge(activity);
    console.log(
      chalk.dim(t.id.padEnd(idWidth)) +
        COL_GAP +
        renderColumn(t.title, COL_TITLE) +
        COL_GAP +
        renderColumn(t.type, COL_TYPE, chalk.dim) +
        COL_GAP +
        renderColumn(priorityLabel(t.priority), COL_PRI, (text) => colorPriority(text, t.priority)) +
        COL_GAP +
        renderColumn(t.status, COL_STATUS, statusChalk) +
        COL_GAP +
        renderColumn(runBadge, runColWidth, (s) => s) +
        prCell,
    );
  }
}

// ── foreman task create ───────────────────────────────────────────────────────

const createCommand = new Command("create")
  .description("Create a new task in backlog status")
  .option("--title <text>", "Task title (required unless --from-text is used)")
  .option("--description <text>", "Optional task description")
  .option(
    "--type <type>",
    "Task type: task, bug, feature, epic, chore, docs, question (default: task)",
  )
  .option(
    "--priority <level>",
    "Priority: 0-4 or critical/high/medium/low/backlog (default: medium)",
  )
  .option(
    "--from-text <description>",
    "Removed: natural-language task generation is not available after the Elixir backend cutover",
  )
  .option("--parent <id>", "Parent task ID (only with --from-text)")
  .option("--dry-run", "Show what would be created without creating tasks (only with --from-text)")
  .option("--no-llm", "Skip LLM parsing — create a single task with the text as title (only with --from-text)")
  .option("--model <model>", "Claude model to use for parsing (only with --from-text)")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(
    async (opts: {
      title?: string;
      description?: string;
      type?: string;
      priority?: string;
      fromText?: string;
      parent?: string;
      dryRun?: boolean;
      llm: boolean; // false when --no-llm is passed
      model?: string;
      project?: string;
      projectPath?: string;
    }) => {
      // ── Removed natural-language path (--from-text), formerly shared with 'foreman task' ──
      if (opts.fromText !== undefined) {
        console.error(chalk.red("Error: task create --from-text was removed after the Elixir backend cutover."));
        console.error(chalk.dim("  Use structured task creation: foreman task create --title <text> [--description <text>]"));
        process.exit(1);
      }

      // ── Structured path ───────────────────────────────────────────────
      const fromTextOnly: string[] = [];
      if (opts.parent !== undefined) fromTextOnly.push("--parent");
      if (opts.dryRun) fromTextOnly.push("--dry-run");
      if (opts.model !== undefined) fromTextOnly.push("--model");
      if (opts.llm === false) fromTextOnly.push("--no-llm");
      if (fromTextOnly.length > 0) {
        console.error(
          chalk.red(`Error: ${fromTextOnly.join(", ")} require(s) --from-text.`),
        );
        process.exit(1);
      }

      if (opts.title === undefined) {
        console.error(
          chalk.red("Error: --title is required."),
        );
        process.exit(1);
      }
      const title: string = opts.title;
      const typeInput = opts.type ?? "task";
      const priorityInput = opts.priority ?? "medium";

      let priority: number;
      try {
        priority = parsePriority(priorityInput);
      } catch {
        console.error(
          chalk.red(
            `Error: Invalid priority '${priorityInput}'. Use 0-4 or: critical, high, medium, low, backlog`,
          ),
        );
        process.exit(1);
      }

      if (!VALID_TASK_TYPES.includes(typeInput)) {
        console.error(
          chalk.red(
            `Error: Invalid type '${typeInput}'. Valid types: ${VALID_TASK_TYPES.join(", ")}`,
          ),
        );
        process.exit(1);
      }

      try {
        if (foremanBackendMode() === "elixir") {
          const { projectId, projectName } = await resolveTaskProjectRegistration(opts);
          const client = await createElixirTaskCommandClient();
          const existingIds = new Set((await listAllElixirTasks(client, projectId)).map((task) => task.id));
          const taskId = allocateTaskId(projectName, existingIds);
          await sendElixirTaskCommand(client, "task.create", {
            project_id: projectId,
            task_id: taskId,
            title,
            description: opts.description,
            task_type: typeInput,
            priority,
            status: "backlog",
          });
          const createdTask = await getElixirTaskRow(client, taskId);
          if (!createdTask) {
            throw new Error(`Task '${taskId}' not found.`);
          }

          console.log(
            chalk.green(`✓ Task created`) + chalk.dim(` [${createdTask.id}]`),
          );
          console.log(`  Title:    ${createdTask.title}`);
          console.log(`  Type:     ${createdTask.type}`);
          console.log(`  Priority: ${priorityLabel(createdTask.priority)}`);
          console.log(`  Status:   ${createdTask.status}`);
          console.log(
            chalk.dim(`\n  Run 'foreman task approve ${createdTask.id}' to make it ready for dispatch.`),
          );
          return;
        }

        const { client, projectId, projectName } = await resolveTaskProjectContext(opts);
        const existingIds = new Set((await listAllTasks(client, projectId)).map((task) => task.id));
        const taskId = allocateTaskId(projectName, existingIds);
        const task = await client.tasks.create({
          projectId,
          id: taskId,
          title,
          description: opts.description,
          type: typeInput,
          priority,
        });
        const createdTask = task as TaskRow;

        console.log(
          chalk.green(`✓ Task created`) + chalk.dim(` [${createdTask.id}]`),
        );
        console.log(`  Title:    ${createdTask.title}`);
        console.log(`  Type:     ${createdTask.type}`);
        console.log(`  Priority: ${priorityLabel(createdTask.priority)}`);
        console.log(`  Status:   ${createdTask.status}`);
        console.log(
          chalk.dim(`\n  Run 'foreman task approve ${createdTask.id}' to make it ready for dispatch.`),
        );
      } catch (err) {
        console.error(chalk.red(`Error: ${err instanceof Error ? err.message : String(err)}`));
        process.exit(1);
      }
    },
  );

// ── foreman task list ─────────────────────────────────────────────────────────

const listCommand = new Command("list")
  .description("List tasks from the Elixir-backed task store")
  .option("--status <status>", "Filter by task status (e.g. ready, backlog, in-progress)")
  .option("--run-status <status>", "Filter by run status (e.g. running, stuck, failed, completed)")
  .option("--type <type>", "Filter by type (e.g. epic, bug, feature, task)")
  .option("--all", "Include closed and merged tasks (excluded by default)")
  .option("--show-pr", "Show GitHub PR state for each task")
  .option("--show-run", "Show run status column for each task")
  .option("--stuck", "Show only tasks with stuck or stale runs")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(async (opts: { status?: string; runStatus?: string; type?: string; all?: boolean; showPr?: boolean; showRun?: boolean; stuck?: boolean; project?: string; projectPath?: string }) => {
    try {
      if (foremanBackendMode() === "elixir") {
        const { projectId, projectPath } = await resolveTaskProjectRegistration(opts);
        const client = await createElixirTaskCommandClient();
        let rows = await listAllElixirTasks(client, projectId);

        if (opts.status) {
          rows = rows.filter((row) => row.status === opts.status);
        } else if (!opts.all) {
          rows = rows.filter((row) => row.status !== "closed" && row.status !== "merged");
        }

        if (opts.type) {
          rows = rows.filter((row) => row.type === opts.type);
        }

        rows = [...rows].sort(
          (a, b) => a.priority - b.priority || a.created_at.localeCompare(b.created_at),
        );

        const runActivityMap = new Map<string, RunActivityInfo | null>();
        const needsRunActivity = opts.runStatus || opts.stuck || opts.showRun;
        if (needsRunActivity) {
          const fetches = rows.map(async (task) => {
            const activity = task.run_id ? await fetchRunActivity(projectPath, task.run_id, projectId) : null;
            runActivityMap.set(task.id, activity);
          });
          await Promise.all(fetches);
        }

        if (opts.runStatus) {
          rows = rows.filter((row) => {
            const activity = runActivityMap.get(row.id);
            return activity?.status === opts.runStatus;
          });
        }

        if (opts.stuck) {
          rows = rows.filter((row) => {
            const activity = runActivityMap.get(row.id);
            return activity?.isStuck || activity?.isStale || activity?.status === "stuck";
          });
        }

        if (rows.length === 0) {
          if (opts.status && opts.type) {
            console.log(chalk.dim(`No tasks with status '${opts.status}' and type '${opts.type}'.`));
          } else if (opts.status) {
            console.log(chalk.dim(`No tasks with status '${opts.status}'.`));
          } else if (opts.type) {
            console.log(chalk.dim(`No tasks with type '${opts.type}'.`));
          } else if (opts.runStatus) {
            console.log(chalk.dim(`No tasks with run status '${opts.runStatus}'.`));
          } else if (opts.stuck) {
            console.log(chalk.dim(`No stuck or stale tasks found.`));
          } else {
            console.log(chalk.dim("No tasks found. Use 'foreman task create' to add tasks."));
          }
          return;
        }

        const label = opts.status
          ? opts.type
            ? `Tasks (status: ${opts.status}, type: ${opts.type})`
            : `Tasks (status: ${opts.status})`
          : opts.type
            ? `Tasks (type: ${opts.type})`
            : opts.all
              ? `All Tasks`
              : `Active Tasks`;
        console.log(chalk.bold(`\n  ${label} (${rows.length})\n`));
        if (opts.showRun || opts.stuck) {
          printTaskTableWithRunStatus(rows, runActivityMap);
        } else {
          printTaskTable(rows);
        }
        console.log();
        return;
      }

      const { client, projectId, projectPath } = await resolveTaskProjectContext(opts);
      let rows = await listAllTasks(client, projectId);

      if (opts.status) {
        rows = rows.filter((row) => row.status === opts.status);
      } else if (!opts.all) {
        rows = rows.filter((row) => row.status !== "closed" && row.status !== "merged");
      }

      if (opts.type) {
        rows = rows.filter((row) => row.type === opts.type);
      }

      rows = [...rows].sort(
        (a, b) => a.priority - b.priority || a.created_at.localeCompare(b.created_at),
      );

      // Fetch run activity for tasks with run_ids (when filtering by run status or --stuck)
      const runActivityMap = new Map<string, RunActivityInfo | null>();
      const needsRunActivity = opts.runStatus || opts.stuck || opts.showRun;
      if (needsRunActivity) {
        const fetches = rows.map(async (task) => {
          const activity = task.run_id ? await fetchRunActivity(projectPath, task.run_id) : null;
          runActivityMap.set(task.id, activity);
        });
        await Promise.all(fetches);
      }

      // Filter by run status if specified
      if (opts.runStatus) {
        rows = rows.filter((row) => {
          const activity = runActivityMap.get(row.id);
          return activity?.status === opts.runStatus;
        });
      }

      // Filter to stuck/stale runs only
      if (opts.stuck) {
        rows = rows.filter((row) => {
          const activity = runActivityMap.get(row.id);
          return activity?.isStuck || activity?.isStale || activity?.status === "stuck";
        });
      }

      if (rows.length === 0) {
        if (opts.status && opts.type) {
          console.log(chalk.dim(`No tasks with status '${opts.status}' and type '${opts.type}'.`));
        } else if (opts.status) {
          console.log(chalk.dim(`No tasks with status '${opts.status}'.`));
        } else if (opts.type) {
          console.log(chalk.dim(`No tasks with type '${opts.type}'.`));
        } else if (opts.runStatus) {
          console.log(chalk.dim(`No tasks with run status '${opts.runStatus}'.`));
        } else if (opts.stuck) {
          console.log(chalk.dim(`No stuck or stale tasks found.`));
        } else {
          console.log(
            chalk.dim("No tasks found. Use 'foreman task create' to add tasks."),
          );
        }
        return;
      }

      // Fetch PR states if --show-pr is specified
      let prStates: Map<string, PrState> | undefined;
      if (opts.showPr) {
        prStates = new Map<string, PrState>();
        await Promise.all(
          rows.map(async (task) => {
            try {
              const prState = await client.tasks.getPrState({ projectId, taskId: task.id }) as PrState;
              prStates!.set(task.id, prState);
            } catch {
              // PR state fetch failed - leave as undefined
            }
          })
        );
      }

      // Run status summary for stuck runs
      if (opts.stuck && rows.length > 0) {
        const stuckCount = rows.filter((row) => {
          const activity = runActivityMap.get(row.id);
          return activity?.isStuck || activity?.status === "stuck";
        }).length;
        const staleCount = rows.length - stuckCount;
        console.log(chalk.bold(`\n  Stuck/Stale Tasks (${rows.length})\n`));
        if (stuckCount > 0) {
          console.log(chalk.red(`  ⚠ ${stuckCount} stuck (no activity > 15min)`));
        }
        if (staleCount > 0) {
          console.log(chalk.yellow(`  ⚡ ${staleCount} stale (reduced activity)`));
        }
        console.log();
        printTaskTableWithRunStatus(rows, runActivityMap, prStates);
      } else {
        const label = opts.status
          ? opts.type
            ? `Tasks (status: ${opts.status}, type: ${opts.type})`
            : `Tasks (status: ${opts.status})`
          : opts.type
            ? `Tasks (type: ${opts.type})`
            : opts.all
              ? `All Tasks`
              : `Active Tasks`;
        console.log(chalk.bold(`\n  ${label} (${rows.length})\n`));
        if (opts.showRun) {
          printTaskTableWithRunStatus(rows, runActivityMap, prStates);
        } else {
          printTaskTable(rows, prStates);
        }
      }
      console.log();
    } catch (err) {
      console.error(chalk.red(`Error: ${err instanceof Error ? err.message : String(err)}`));
      process.exit(1);
    }
  });

// ── foreman task show ─────────────────────────────────────────────────────────

const showCommand = new Command("show")
  .description("Show details of a specific task")
  .argument("<id>", "Task ID (or short prefix)")
  .option("--verbose", "Show detailed run activity information")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(async (id: string, opts: { verbose?: boolean; project?: string; projectPath?: string }) => {
    try {
      if (foremanBackendMode() === "elixir") {
        const { projectId, projectName, projectPath } = await resolveTaskProjectRegistration(opts);
        const client = await createElixirTaskCommandClient();
        const rows = await listAllElixirTasks(client, projectId);
        const resolvedId = resolveTaskId(rows, id);
        const task = await client.getTask(resolvedId);
        if (!task) {
          console.error(chalk.red(`Error: Task '${id}' not found.`));
          process.exit(1);
        }

        const taskRow = elixirTaskToTaskRow(task);
        console.log(chalk.bold(`\n  Task: ${taskRow.title}`));
        console.log(`  ID:          ${taskRow.id}`);
        console.log(`  Type:        ${taskRow.type}`);
        console.log(`  Priority:    ${priorityLabel(taskRow.priority)} (${taskRow.priority})`);
        console.log(`  Status:      ${statusChalk(taskRow.status)}`);
        if (taskRow.description) {
          console.log(`  Description: ${taskRow.description}`);
        }
        if (taskRow.run_id) {
          console.log(`  Run ID:      ${taskRow.run_id}`);
        }
        if (taskRow.external_id) {
          console.log(`  External ID: ${taskRow.external_id}`);
        }
        console.log(`  Created:     ${new Date(taskRow.created_at).toLocaleString()}`);
        console.log(`  Updated:     ${new Date(taskRow.updated_at).toLocaleString()}`);
        if (taskRow.approved_at) {
          console.log(`  Approved:    ${new Date(taskRow.approved_at).toLocaleString()}`);
        }
        if (taskRow.closed_at) {
          console.log(`  Closed:      ${new Date(taskRow.closed_at).toLocaleString()}`);
        }
        if (taskRow.run_id) {
          console.log(chalk.bold("\n  Logs:"));
          console.log(`    Summary:    foreman logs ${taskRow.id} --project ${projectName}`);
          console.log(`    Follow:     foreman logs ${taskRow.id} --project ${projectName} --follow`);
          console.log(chalk.dim(`    Raw:        ~/.foreman/logs/${taskRow.run_id}.log`));
        }

        if (taskRow.run_id) {
          const activity = await fetchRunActivity(projectPath, taskRow.run_id, projectId);
          if (activity) {
            console.log(chalk.bold("\n  Run Activity:"));
            console.log(`    ${renderRunStatusLine(activity)}`);
            if (opts.verbose && activity.currentPhase) {
              console.log();
              console.log(chalk.dim(`    Current phase: ${activity.currentPhase}`));
            }
          } else if (opts.verbose) {
            console.log(chalk.dim(`\n  Run Activity: run ${taskRow.run_id} not found (may have been cleaned up)`));
          }
        }

        console.log(chalk.bold("\n  Notes:"));
        const annotations = Array.isArray(task.annotations) ? task.annotations : [];
        if (annotations.length === 0) {
          console.log(chalk.dim("    (none yet)"));
        } else {
          for (const note of annotations) {
            const when = note.created_at ? new Date(note.created_at).toLocaleString() : "unknown time";
            console.log(chalk.dim(`    [${when} manual] ${note.author ?? "unknown"}`));
            for (const line of note.body.split("\n")) {
              console.log(`    ${line}`);
            }
          }
        }

        const outgoingDeps = Array.isArray(task.dependencies) ? task.dependencies : [];
        const incomingDeps = rows.filter((row) => Array.isArray((row as unknown as { dependencies?: string[] }).dependencies) && ((row as unknown as { dependencies?: string[] }).dependencies?.includes(taskRow.id)));
        if (incomingDeps.length > 0) {
          console.log(chalk.bold("\n  Blocked by:"));
          for (const dep of incomingDeps) {
            console.log(chalk.yellow(`    [blocks] ← ${formatTaskIdDisplay(dep.id)}`));
          }
        }
        if (outgoingDeps.length > 0) {
          console.log(chalk.bold("\n  Blocking:"));
          for (const depId of outgoingDeps) {
            console.log(chalk.dim(`    [blocks] → ${formatTaskIdDisplay(depId)}`));
          }
        }
        console.log();
        return;
      }

      const { client, projectId, projectName, projectPath } = await resolveTaskProjectContext(opts);
      const rows = await listAllTasks(client, projectId);
      const resolvedId = resolveTaskId(rows, id);
      const task = await client.tasks.get({ projectId, taskId: resolvedId }) as TaskRow | null;
      if (!task) {
        console.error(chalk.red(`Error: Task '${id}' not found.`));
        process.exit(1);
      }

      console.log(chalk.bold(`\n  Task: ${task.title}`));
      console.log(`  ID:          ${task.id}`);
      console.log(`  Type:        ${task.type}`);
      console.log(`  Priority:    ${priorityLabel(task.priority)} (${task.priority})`);
      console.log(`  Status:      ${statusChalk(task.status)}`);
      if (task.description) {
        console.log(`  Description: ${task.description}`);
      }
      if (task.run_id) {
        console.log(`  Run ID:      ${task.run_id}`);
      }
      if (task.branch) {
        console.log(`  Branch:      ${task.branch}`);
      }
      if (task.external_id) {
        console.log(`  External ID: ${task.external_id}`);
      }
      console.log(`  Created:     ${new Date(task.created_at).toLocaleString()}`);
      console.log(`  Updated:     ${new Date(task.updated_at).toLocaleString()}`);
      if (task.approved_at) {
        console.log(`  Approved:    ${new Date(task.approved_at).toLocaleString()}`);
      }
      if (task.closed_at) {
        console.log(`  Closed:      ${new Date(task.closed_at).toLocaleString()}`);
      }
      if (task.run_id) {
        console.log(chalk.bold("\n  Logs:"));
        console.log(`    Summary:    foreman logs ${task.id} --project ${projectName}`);
        console.log(`    Follow:     foreman logs ${task.id} --project ${projectName} --follow`);
        console.log(chalk.dim(`    Raw:        ~/.foreman/logs/${task.run_id}.log`));
      }

      // ── Live Run Activity Section ─────────────────────────────────────────
      // Fetch current run state from the Postgres store (mirrors dashboard data)
      // Only shown for tasks with an active run_id to avoid unnecessary DB access
      if (task.run_id) {
        const activity = await fetchRunActivity(projectPath, task.run_id);
        if (activity) {
          console.log(chalk.bold("\n  Run Activity:"));

          // Status line with color-coded indicators
          const statusLine = renderRunStatusLine(activity);
          console.log(`    ${statusLine}`);

          // Stuck/warning alert
          if (activity.isStuck) {
            console.log();
            console.log(chalk.red(`    ⚠ WARNING: This run appears STUCK.`) + chalk.dim(` No activity for > 15 minutes.`));
            console.log(chalk.dim(`    Check logs: ~/.foreman/logs/${activity.runId}.log`));
            console.log(chalk.dim(`    Stuck runs can be reset with: foreman task reset ${task.id}`));
          }

          // Phase timeline for completed/failed runs
          if (opts.verbose && activity.currentPhase) {
            console.log();
            console.log(chalk.dim(`    Current phase: ${activity.currentPhase}`));
          }

          // Tool/progress stats for verbose or active runs
          if (opts.verbose || activity.status === "running") {
            if (activity.toolCalls > 0) {
              console.log(`    Tools used: ${chalk.cyan(String(activity.toolCalls))}`);
            }
            if (activity.turns > 0) {
              console.log(`    Turns:      ${chalk.cyan(String(activity.turns))}`);
            }
            if (activity.costUsd > 0) {
              console.log(`    Cost:       $${activity.costUsd.toFixed(4)}`);
            }
            if (activity.lastActivity) {
              console.log(`    Last activity: ${new Date(activity.lastActivity).toLocaleString()}`);
            }
            if (activity.startedAt) {
              console.log(`    Started:    ${new Date(activity.startedAt).toLocaleString()}`);
            }
            if (activity.completedAt) {
              console.log(`    Completed:  ${new Date(activity.completedAt).toLocaleString()}`);
            }
          }

          // Terminal failure summary
          if (activity.status === "failed" || activity.status === "test-failed") {
            console.log();
            console.log(chalk.red(`    ✗ This run FAILED.`) + chalk.dim(` Check logs for details:`));
            console.log(chalk.dim(`    ~/.foreman/logs/${activity.runId}.log`));
            console.log(chalk.dim(`    To retry: foreman task retry ${task.id}`));
          }

          // Success/completion summary
          if (activity.status === "completed" || activity.status === "merged") {
            console.log();
            console.log(chalk.green(`    ✓ Run completed successfully.`) + chalk.dim(` Waiting for merge.`));
          }
        } else if (opts.verbose) {
          // Task has run_id but no run found (may be cleaned up)
          console.log(chalk.dim(`\n  Run Activity: run ${task.run_id} not found (may have been cleaned up)`));
        }
      }

      // Show PR state
      try {
        const prState = await client.tasks.getPrState({ projectId, taskId: task.id }) as PrState;
        if (prState) {
          console.log(chalk.bold("\n  Pull Request:"));
          console.log(`    Status:     ${renderPrBadge(prState)}`);
          if (prState.url) {
            console.log(`    URL:        ${prState.url}`);
          }
          if (prState.number) {
            console.log(`    Number:     #${prState.number}`);
          }
          if (prState.headSha) {
            console.log(`    PR Head:    ${chalk.dim(prState.headSha.slice(0, 12))}`);
          }
          if (prState.currentHeadSha) {
            console.log(`    Branch Head: ${chalk.dim(prState.currentHeadSha.slice(0, 12))}`);
          }
          if (prState.isStale) {
            console.log(chalk.yellow(`    ⚠ Stale:    PR merged but branch has been updated since`));
          }
          if (prState.error) {
            console.log(chalk.red(`    Error:      ${prState.error}`));
          }
        }
      } catch {
        // PR state fetch failed - don't show anything
      }

      // Show notes timeline
      try {
        const notes = [...await client.tasks.listNotes({
          projectId,
          taskId: task.id,
          limit: 25,
          newestFirst: true,
        }) as TaskNoteRow[]].reverse();
        console.log(chalk.bold("\n  Notes:"));
        if (notes.length === 0) {
          console.log(chalk.dim("    (none yet)"));
        } else {
          for (const note of notes) {
            const when = new Date(note.created_at).toLocaleString();
            const phase = note.phase ? ` ${note.phase}` : "";
            console.log(chalk.dim(`    [${when}${phase} ${note.kind}] ${note.author}`));
            for (const line of note.body.split("\n")) {
              console.log(`    ${line}`);
            }
          }
        }
      } catch (err) {
        console.log(chalk.bold("\n  Notes:"));
        console.log(chalk.dim(`    unavailable: ${err instanceof Error ? err.message : String(err)}`));
      }

      // Show dependencies
      const outgoing = await client.tasks.listDependencies({
        projectId,
        taskId: task.id,
        direction: "outgoing",
      }) as DependencyRow[];
      const incoming = await client.tasks.listDependencies({
        projectId,
        taskId: task.id,
        direction: "incoming",
      }) as DependencyRow[];

      if (incoming.length > 0) {
        console.log(chalk.bold("\n  Blocked by:"));
        for (const dep of incoming) {
          console.log(chalk.yellow(`    [${dep.type}] ← ${formatTaskIdDisplay(dep.from_task_id)}`));
        }
      }

      if (outgoing.length > 0) {
        console.log(chalk.bold("\n  Blocking:"));
        for (const dep of outgoing) {
          console.log(chalk.dim(`    [${dep.type}] → ${formatTaskIdDisplay(dep.to_task_id)}`));
        }
      }
      console.log();
    } catch (err) {
      console.error(chalk.red(`Error: ${err instanceof Error ? err.message : String(err)}`));
      process.exit(1);
    }
  });

// ── foreman task note ─────────────────────────────────────────────────────────

const noteCommand = new Command("note")
  .description("Append a note to a task")
  .argument("<id>", "Task ID (or short prefix)")
  .requiredOption("--body <text>", "Note body")
  .option("--kind <kind>", "Note kind: progress, issue, blocker, review, qa, final, failure, manual, system", "manual")
  .option("--author <name>", "Note author", "user")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(async (id: string, opts: { body: string; kind: string; author: string; project?: string; projectPath?: string }) => {
    try {
      const { projectId } = await resolveTaskProjectRegistration(opts);
      const client = await createElixirTaskCommandClient();
      const rows = await listAllElixirTasks(client, projectId);
      const resolvedId = resolveTaskId(rows, id);
      await sendElixirTaskCommand(client, "task.annotate", {
        project_id: projectId,
        task_id: resolvedId,
        author: opts.author,
        kind: opts.kind,
        body: opts.body,
      });
      console.log(chalk.green(`✓ Note added to '${formatTaskIdDisplay(resolvedId)}'.`));
    } catch (err) {
      console.error(chalk.red(`Error: ${err instanceof Error ? err.message : String(err)}`));
      process.exit(1);
    }
  });

// ── foreman task approve ──────────────────────────────────────────────────────

const approveCommand = new Command("approve")
  .description("Approve a backlog task, making it ready for dispatch")
  .argument("<id>", "Task ID")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(async (id: string, opts: { project?: string; projectPath?: string }) => {
    try {
      if (foremanBackendMode() === "elixir") {
        const { projectId } = await resolveTaskProjectRegistration(opts);
        const client = await createElixirTaskCommandClient();
        const rows = await listAllElixirTasks(client, projectId);
        const resolvedId = resolveTaskId(rows, id);
        await sendElixirTaskCommand(client, "task.approve", { project_id: projectId, task_id: resolvedId });
        const task = await getElixirTaskRow(client, resolvedId);
        if (task?.status === "ready") {
          console.log(
            chalk.green(`✓ Task '${formatTaskIdDisplay(resolvedId)}' approved and ready for dispatch.`),
          );
        } else {
          console.log(chalk.green(`✓ Task '${formatTaskIdDisplay(resolvedId)}' approved.`));
          if (task?.status) {
            console.log(chalk.dim(`  Status: ${task.status}`));
          }
        }
        return;
      }

      const { client, projectId } = await resolveTaskProjectContext(opts);
      const rows = await listAllTasks(client, projectId);
      const resolvedId = resolveTaskId(rows, id);
      const task = await client.tasks.approve({ projectId, taskId: resolvedId }) as TaskRow | null;
      if (task?.status === "ready") {
        console.log(
          chalk.green(`✓ Task '${formatTaskIdDisplay(resolvedId)}' approved and ready for dispatch.`),
        );
      } else {
        console.log(chalk.green(`✓ Task '${formatTaskIdDisplay(resolvedId)}' approved.`));
        if (task?.status) {
          console.log(chalk.dim(`  Status: ${task.status}`));
        }
      }
    } catch (err) {
      console.error(chalk.red(`Error: ${err instanceof Error ? err.message : String(err)}`));
      process.exit(1);
    }
  });

// ── foreman task update ───────────────────────────────────────────────────────

const updateCommand = new Command("update")
  .description("Update fields on an existing task")
  .argument("<id>", "Task ID")
  .option("--title <text>", "New task title")
  .option("--description <text>", "New task description (use --no-description to clear)")
  .option("--no-description", "Clear the description field")
  .option("--priority <level>", "New priority: 0-4 or critical/high/medium/low/backlog")
  .option("--status <status>", "New status (e.g. backlog, ready, in-progress)")
  .option("--force", "Allow backward status transitions (e.g. merged → backlog)")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(
    async (id: string, opts: {
      title?: string;
      description?: string | boolean;
      noDescription?: boolean;
      priority?: string;
      status?: string;
      force?: boolean;
      project?: string;
      projectPath?: string;
    }) => {
      const updateOpts: {
        title?: string;
        description?: string | null;
        priority?: number;
        status?: string;
        force?: boolean;
      } = {};

      if (opts.title !== undefined) {
        updateOpts.title = opts.title;
      }
      if (opts.noDescription || opts.description === false) {
        updateOpts.description = null;
      } else if (typeof opts.description === "string") {
        updateOpts.description = opts.description;
      }
      if (opts.priority !== undefined) {
        try {
          updateOpts.priority = parsePriority(opts.priority);
        } catch {
          console.error(
            chalk.red(
              `Error: Invalid priority '${opts.priority}'. Use 0-4 or: critical, high, medium, low, backlog`,
            ),
          );
          process.exit(1);
        }
      }
      if (opts.status !== undefined) {
        updateOpts.status = opts.status;
      }
      if (opts.force) {
        updateOpts.force = true;
      }

      try {
        if (foremanBackendMode() === "elixir") {
          const { projectId } = await resolveTaskProjectRegistration(opts);
          const client = await createElixirTaskCommandClient();
          const rows = await listAllElixirTasks(client, projectId);
          const resolvedId = resolveTaskId(rows, id);

          if (updateOpts.status !== undefined && !updateOpts.force) {
            const current = rows.find((row) => row.id === resolvedId);
            if (current && isBackwardStatusTransition(current.status, updateOpts.status)) {
              console.error(
                chalk.red(
                  `Error: Task '${formatTaskIdDisplay(resolvedId)}' cannot transition from '${current.status}' to '${updateOpts.status}'.`,
                ),
              );
              console.error(chalk.dim("  Use --force to override this check."));
              process.exit(1);
            }
          }

          await sendElixirTaskCommand(client, "task.update", {
            project_id: projectId,
            task_id: resolvedId,
            title: updateOpts.title,
            description: updateOpts.description ?? undefined,
            priority: updateOpts.priority,
            status: updateOpts.status,
          });
          const task = await getElixirTaskRow(client, resolvedId);
          if (!task) {
            throw new Error(`Task '${resolvedId}' not found.`);
          }

          console.log(chalk.green(`✓ Task '${formatTaskIdDisplay(resolvedId)}' updated.`));
          console.log(`  Title:    ${task.title}`);
          console.log(`  Type:     ${task.type}`);
          console.log(`  Priority: ${priorityLabel(task.priority)}`);
          console.log(`  Status:   ${statusChalk(task.status)}`);
          if (task.description) {
            console.log(`  Description: ${task.description}`);
          }
          return;
        }

        const { client, projectId } = await resolveTaskProjectContext(opts);
        const rows = await listAllTasks(client, projectId);
        const resolvedId = resolveTaskId(rows, id);

        if (updateOpts.status !== undefined && !updateOpts.force) {
          const current = rows.find((row) => row.id === resolvedId);
          if (current && isBackwardStatusTransition(current.status, updateOpts.status)) {
            console.error(
              chalk.red(
                `Error: Task '${formatTaskIdDisplay(resolvedId)}' cannot transition from '${current.status}' to '${updateOpts.status}'.`,
              ),
            );
            console.error(chalk.dim("  Use --force to override this check."));
            process.exit(1);
          }
        }

        const task = await client.tasks.update({
          projectId,
          taskId: resolvedId,
          updates: {
            title: updateOpts.title,
            description: updateOpts.description ?? undefined,
            priority: updateOpts.priority,
            status: updateOpts.status,
          },
        }) as TaskRow | null;
        if (!task) {
          throw new Error(`Task '${resolvedId}' not found.`);
        }

        console.log(chalk.green(`✓ Task '${formatTaskIdDisplay(resolvedId)}' updated.`));
        console.log(`  Title:    ${task.title}`);
        console.log(`  Type:     ${task.type}`);
        console.log(`  Priority: ${priorityLabel(task.priority)}`);
        console.log(`  Status:   ${statusChalk(task.status)}`);
        if (task.description) {
          console.log(`  Description: ${task.description}`);
        }
      } catch (err) {
        console.error(chalk.red(`Error: ${err instanceof Error ? err.message : String(err)}`));
        process.exit(1);
      }
    },
  );

// ── foreman task close ────────────────────────────────────────────────────────

const closeCommand = new Command("close")
  .description("Close a task (mark as merged)")
  .argument("<id>", "Task ID")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(async (id: string, opts: { project?: string; projectPath?: string }) => {
    try {
      if (foremanBackendMode() === "elixir") {
        const { projectId } = await resolveTaskProjectRegistration(opts);
        const client = await createElixirTaskCommandClient();
        const rows = await listAllElixirTasks(client, projectId);
        const resolvedId = resolveTaskId(rows, id);
        await sendElixirTaskCommand(client, "task.close", { project_id: projectId, task_id: resolvedId });

        console.log(chalk.green(`✓ Task '${formatTaskIdDisplay(resolvedId)}' closed.`));
        return;
      }

      const { client, projectId } = await resolveTaskProjectContext(opts);
      const rows = await listAllTasks(client, projectId);
      const resolvedId = resolveTaskId(rows, id);
      await client.tasks.close({ projectId, taskId: resolvedId });

      console.log(chalk.green(`✓ Task '${formatTaskIdDisplay(resolvedId)}' closed.`));
    } catch (err) {
      console.error(chalk.red(`Error: ${err instanceof Error ? err.message : String(err)}`));
      process.exit(1);
    }
  });

// ── foreman task dep ──────────────────────────────────────────────────────────

const depAddCommand = new Command("add")
  .description("Add a dependency between two tasks (from-id blocks to-id)")
  .argument("<from-id>", "The blocking task ID")
  .argument("<to-id>", "The blocked task ID")
  .option(
    "--type <type>",
    "Dependency type: blocks (default) or parent-child",
    "blocks",
  )
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(
    async (fromId: string, toId: string, opts: { type: string; project?: string; projectPath?: string }) => {
      if (opts.type !== "blocks" && opts.type !== "parent-child") {
        console.error(
          chalk.red(`Error: Invalid type '${opts.type}'. Use 'blocks' or 'parent-child'.`),
        );
        process.exit(1);
      }

      try {
        if (opts.type !== "blocks") {
          console.error(chalk.red("Error: task dep add --type parent-child was removed after the Elixir backend cutover."));
          console.error(chalk.dim("  Elixir task dependencies currently support blocker relationships only."));
          process.exit(1);
        }
        const { projectId } = await resolveTaskProjectRegistration(opts);
        const client = await createElixirTaskCommandClient();
        const rows = await listAllElixirTasks(client, projectId);
        const resolvedFromId = resolveTaskId(rows, fromId);
        const resolvedToId = resolveTaskId(rows, toId);
        await sendElixirTaskCommand(client, "task.add_dependency", {
          project_id: projectId,
          task_id: resolvedToId,
          depends_on: resolvedFromId,
        });
        const verb = opts.type === "blocks" ? "blocks" : "is parent of";
        console.log(
          chalk.green(
            `✓ Dependency added: '${formatTaskIdDisplay(resolvedFromId)}' ${verb} '${formatTaskIdDisplay(resolvedToId)}'.`,
          ),
        );
      } catch (err) {
        if (err instanceof Error && err.message.includes("circular dependency")) {
          console.error(
            chalk.red(`Error: Adding this dependency would create a circular dependency.`),
          );
          process.exit(1);
        }
        console.error(chalk.red(`Error: ${err instanceof Error ? err.message : String(err)}`));
        process.exit(1);
      }
    },
  );

const depListCommand = new Command("list")
  .description("List dependencies for a task")
  .argument("<id>", "Task ID")
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(async (id: string, opts: { project?: string; projectPath?: string }) => {
    try {
      const { projectId } = await resolveTaskProjectRegistration(opts);
      const client = await createElixirTaskCommandClient();
      const rows = await listAllElixirTasks(client, projectId);
      const resolvedId = resolveTaskId(rows, id);
      const current = rows.find((row) => row.id === resolvedId);
      const currentDependencies = ((current as unknown as { dependencies?: string[] } | undefined)?.dependencies ?? []);
      const blockedBy = currentDependencies.map((dependencyId) => ({
        type: "blocks",
        from_task_id: dependencyId,
        to_task_id: resolvedId,
      })) as DependencyRow[];
      const blocking = rows
        .filter((row) => (((row as unknown as { dependencies?: string[] }).dependencies ?? []).includes(resolvedId)))
        .map((row) => ({
          type: "blocks",
          from_task_id: resolvedId,
          to_task_id: row.id,
        })) as DependencyRow[];

      if (blockedBy.length === 0 && blocking.length === 0) {
        console.log(chalk.dim(`Task '${formatTaskIdDisplay(resolvedId)}' has no dependencies.`));
        return;
      }

      if (blockedBy.length > 0) {
        console.log(chalk.bold("\n  Blocked by:"));
        for (const dep of blockedBy) {
          console.log(chalk.yellow(`    [${dep.type}] ← ${formatTaskIdDisplay(dep.from_task_id)}`));
        }
      }

      if (blocking.length > 0) {
        console.log(chalk.bold("\n  Blocking:"));
        for (const dep of blocking) {
          console.log(chalk.dim(`    [${dep.type}] → ${formatTaskIdDisplay(dep.to_task_id)}`));
        }
      }
      console.log();
    } catch (err) {
      console.error(chalk.red(`Error: ${err instanceof Error ? err.message : String(err)}`));
      process.exit(1);
    }
  });

const depRemoveCommand = new Command("remove")
  .description("Remove a dependency between two tasks")
  .argument("<from-id>", "The blocking task ID")
  .argument("<to-id>", "The blocked task ID")
  .option(
    "--type <type>",
    "Dependency type: blocks (default) or parent-child",
    "blocks",
  )
  .option("--project <name>", "Registered project name (default: current directory)")
  .option("--project-path <absolute-path>", "Absolute project path (advanced/script usage)")
  .action(
    async (fromId: string, toId: string, opts: { type: string; project?: string; projectPath?: string }) => {
      void fromId;
      void toId;
      void opts;
      console.error(chalk.red("Error: task dep remove was removed after the Elixir backend cutover."));
      console.error(chalk.dim("  Remove or adjust dependencies through the Elixir task command API when a removal event is available."));
      process.exit(1);
    },
  );

const depCommand = new Command("dep")
  .description("Manage task dependencies")
  .addCommand(depAddCommand)
  .addCommand(depListCommand)
  .addCommand(depRemoveCommand);

// ── Parent command ────────────────────────────────────────────────────────────

export const taskCommand = new Command("task")
  .description("Manage daemon-backed tasks in Foreman")
  .addCommand(createCommand)
  .addCommand(listCommand)
  .addCommand(showCommand)
  .addCommand(noteCommand)
  .addCommand(approveCommand)
  .addCommand(updateCommand)
  .addCommand(closeCommand)
  .addCommand(depCommand);
